import Foundation
import XCTest

@testable import CoachModule
@testable import SharedCore

/// A reusable async gate: callers block in `wait()` until `open()`.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Total callers that have ever blocked (not decremented on release) — lets
    /// tests confirm N pipelines reached this stage.
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A classifier that blocks each call on the gate — simulating a slow LLM so
/// tests can hold pipelines in flight deterministically.
private struct GatedClassifier: UtteranceClassifying {
    let gate: AsyncGate
    func classify(utterance: String, regexHits: Set<RegexDetector.Marker>) async throws -> UtteranceClass {
        await gate.wait()
        return .question
    }
}

private actor SimpleEmbeddingProvider: EmbeddingProvider {
    nonisolated let embeddingKind: EmbeddingProviderKind = .ollama
    func embed(_ texts: [String], route: EmbeddingRoute) async throws -> [[Float]] {
        texts.map { _ in [Float(1), 0, 0] }
    }
}

final class CoachConcurrencyCapTests: XCTestCase {
    private var tempDir: URL!
    private var db: SqliteDatabase!
    private var vectorSearch: VectorSearch!
    private let cfg = EmbeddingConfig(
        provider: "ollama",
        baseURL: URL(string: "http://localhost:11434"),
        model: "nomic-embed-text",
        normalization: .unitL2
    )

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("coach-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("c.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        try await SchemaV19.bootstrap(database: db)
        vectorSearch = VectorSearch(cache: KbCache(db: db), config: cfg)
    }

    override func tearDown() async throws {
        try? await db?.close()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func makeOrchestrator(gate: AsyncGate) async -> CoachOrchestrator {
        let router = ModelRouter()
        await router.register(provider: SimpleEmbeddingProvider())
        let embedder = EmbeddingClient(router: router, config: cfg)
        return CoachOrchestrator(
            embeddingDetector: EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch),
            classifier: GatedClassifier(gate: gate),
            smartRouter: ScriptedSmartRouter(
                outcome: SmartRoutingOutput(
                    mode: .silent, title: "", body: "", attribution: "", usedChunkIds: []
                ))
        )
    }

    /// A question-marked utterance: passes the substance + attention gates, so it
    /// reaches the (gated) classifier.
    private func autoUtterance(_ text: String) -> CoachUtterance {
        CoachUtterance(speakerId: "remote_1", text: text)
    }

    /// The full latest-wins contract: two pipelines fill the in-flight cap, the
    /// third waits in the single "next" slot, a fourth supersedes it (the waiting
    /// one returns nil + the skip is counted and emitted), and once a slot frees
    /// the newest one runs.
    func testLatestWinsSupersedesQueuedCueAndCountsSkip() async throws {
        let gate = AsyncGate()
        let orchestrator = await makeOrchestrator(gate: gate)
        let collector = HealthEventCollector()
        let stream = await orchestrator.healthEvents()
        let pump = Task { for await event in stream { await collector.append(event) } }
        defer { pump.cancel() }

        let uttA = autoUtterance("What is the annual price?")
        let uttB = autoUtterance("How does onboarding work?")
        let uttC = autoUtterance("What about the SLA terms?")
        let uttD = autoUtterance("Which regions do you cover?")
        let taskA = Task { try await orchestrator.enqueue(utterance: uttA) }
        let taskB = Task { try await orchestrator.enqueue(utterance: uttB) }
        let filled = await waitUntil { await gate.arrivals == 2 }
        XCTAssertTrue(filled, "both pipelines must reach the classifier")
        let inFlight = await orchestrator.inFlightIngestCount
        XCTAssertEqual(inFlight, 2)

        // Third utterance queues (cap reached).
        let taskC = Task { try await orchestrator.enqueue(utterance: uttC) }
        let queued = await waitUntil { await orchestrator.hasQueuedCue }
        XCTAssertTrue(queued, "third cue must wait in the pending slot")

        // Fourth supersedes the third: latest-wins.
        let taskD = Task { try await orchestrator.enqueue(utterance: uttD) }
        let cResult = try await taskC.value
        XCTAssertNil(cResult, "superseded cue must return nil, not a stale result")
        let skipped = await orchestrator.skippedCueCount
        XCTAssertEqual(skipped, 1)

        // The skip is emitted, never silent.
        let emitted = await waitUntil { await collector.events.contains(.cueSkipped(totalSkippedThisMeeting: 1)) }
        XCTAssertTrue(emitted, "superseding a cue must emit a cueSkipped health event")

        // Release the gate: A, B and the newest (D) all complete.
        await gate.open()
        let a = try await taskA.value
        let b = try await taskB.value
        let d = try await taskD.value
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotNil(d, "the newest cue must run once a slot frees")

        let drained = await waitUntil { await orchestrator.inFlightIngestCount == 0 }
        XCTAssertTrue(drained, "all slots must be released after completion")

        // beginMeeting resets the per-meeting skip counter.
        await orchestrator.beginMeeting()
        let reset = await orchestrator.skippedCueCount
        XCTAssertEqual(reset, 0)
    }

    /// Manual (userRequested) cues bypass the cap entirely: with both slots full,
    /// a manual ask still enters the pipeline immediately and is never queued or
    /// superseded — the user explicitly asked for help right now.
    func testManualCueBypassesCap() async throws {
        let gate = AsyncGate()
        let orchestrator = await makeOrchestrator(gate: gate)

        let uttA = autoUtterance("What is the annual price?")
        let uttB = autoUtterance("How does onboarding work?")
        let taskA = Task { try await orchestrator.enqueue(utterance: uttA) }
        let taskB = Task { try await orchestrator.enqueue(utterance: uttB) }
        let filled = await waitUntil { await gate.arrivals == 2 }
        XCTAssertTrue(filled)

        let manual = CoachUtterance(
            speakerId: "you", text: "Help me answer this.", userRequested: true)
        let taskM = Task { try await orchestrator.enqueue(utterance: manual) }
        let manualEntered = await waitUntil { await gate.arrivals == 3 }
        XCTAssertTrue(manualEntered, "manual cue must enter the pipeline despite the cap being full")
        let queuedDuringManual = await orchestrator.hasQueuedCue
        XCTAssertFalse(queuedDuringManual, "manual cues never occupy the auto queue slot")
        let inFlight = await orchestrator.inFlightIngestCount
        XCTAssertEqual(inFlight, 2, "manual cues don't consume capped slots")

        await gate.open()
        let m = try await taskM.value
        XCTAssertNotNil(m, "a manual cue is never superseded")
        _ = try await taskA.value
        _ = try await taskB.value
        let skipped = await orchestrator.skippedCueCount
        XCTAssertEqual(skipped, 0, "nothing was skipped in this scenario")
    }
}
