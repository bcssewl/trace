import XCTest

@testable import AppShell
@testable import SharedCore

/// Coverage for the restructured stop/finalisation flow in `MeetingRuntime`:
/// prompt capture teardown with a tracked background tail, session-scoped
/// guards on every UI write (so meeting A's late results can never bleed into
/// meeting B's view), the `summaryPhase` lifecycle including failure + retry,
/// and the double-stop guard.
///
/// Audio capture needs real devices + TCC grants, so these tests activate a
/// session through the no-capture seam and drive the same teardown/tail code
/// paths `stop()` runs in production.
@MainActor
final class MeetingRuntimeFinalizationTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs = []
        super.tearDown()
    }

    // MARK: - Harness

    private func makeTempDir(_ prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeTempDB() async throws -> SqliteDatabase {
        let dir = makeTempDir("meeting-final-db")
        let db = try await SqliteDatabase.open(at: dir.appendingPathComponent("index.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        return db
    }

    private func makeTemplate() -> Template {
        Template.makeBuiltIn(
            id: UUID(),
            name: "Test Meeting Notes",
            description: "",
            systemPrompt: "Transcript: {{transcript}}",
            outputSections: ["Summary"]
        )
    }

    private struct Harness {
        let runtime: MeetingRuntime
        let model: MeetingLiveModel
        let markdownRoot: String
    }

    private func makeHarness(
        database: SqliteDatabase,
        router: any ModelRoutingFacade,
        generateTitle: (@Sendable (String) async -> String?)? = nil
    ) -> Harness {
        let root = makeTempDir("meeting-final-md").path
        let model = MeetingLiveModel()
        let template = makeTemplate()
        let runtime = MeetingRuntime(
            database: database,
            markdownRoot: root,
            liveModel: model,
            activeCapture: ActiveCaptureModel(),
            asrResolver: { _ in nil },
            merger: MeetingNotesMerger(router: router),
            resolveTemplate: { template },
            generateTitle: generateTitle
        )
        return Harness(runtime: runtime, model: model, markdownRoot: root)
    }

    private func addSpeech(_ model: MeetingLiveModel) {
        model.appendCommitted(
            Utterance(
                t: 1, speaker: .you,
                text: "We agreed to ship the release on Friday after design sign-off.",
                conf: 0.9, asr: "parakeet", diar: nil, cleaned: nil))
        model.appendCommitted(
            Utterance(
                t: 4, speaker: .other(id: "remote_1"),
                text: "I will own the rollout checklist and report back on Monday.",
                conf: 0.9, asr: "parakeet", diar: nil, cleaned: nil))
    }

    private func summaryURL(root: String, sessionId: String) -> URL {
        URL(fileURLWithPath: root)
            .appendingPathComponent("inbox", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("summary.md")
    }

    /// Poll the main actor until `condition` holds (finalisation runs as a real
    /// async task, so tests await observable state rather than internal hops).
    private func waitUntil(
        timeout: TimeInterval = 10,
        _ what: String,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for: \(what)")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Detached stop: prompt return + phase lifecycle + completion callback

    func testDetachedStopReturnsPromptlyAndPhasesProgressToDone() async throws {
        let db = try await makeTempDB()
        let router = GatedScriptedRouter(
            scripted: [
                LLMDelta(textIncrement: "## Decisions\n"),
                LLMDelta(textIncrement: "- Ship Friday.", isFinal: true),
            ],
            gated: true
        )
        let harness = makeHarness(database: db, router: router)
        var completedSessions: [String] = []
        harness.runtime.onFinalizeComplete = { sid in completedSessions.append(sid) }

        let sid = try await harness.runtime.activateSessionWithoutCapture(title: "Meeting 2026-06-09 10:00")
        addSpeech(harness.model)

        // The gate is closed, so the summary stream cannot complete — yet the
        // detached stop must return promptly with capture sealed.
        await harness.runtime.stop(detachedFinalize: true)

        XCTAssertFalse(harness.runtime.isCapturing, "Capture must be sealed when detached stop returns")
        XCTAssertTrue(harness.runtime.isFinalizing, "The tail must still be running")
        XCTAssertNotEqual(
            harness.model.summaryPhase, .done,
            "Detached stop must not have waited for the summary")
        XCTAssertTrue(completedSessions.isEmpty, "Completion fires only when the tail finishes")

        // The tail reaches the streaming stage and parks on the gate.
        await waitUntil("summaryPhase == .generating") { harness.model.summaryPhase == .generating }

        await router.open()

        await waitUntil("summaryPhase == .done") { harness.model.summaryPhase == .done }
        XCTAssertEqual(harness.model.liveSummary, "## Decisions\n- Ship Friday.")
        XCTAssertEqual(harness.model.summaryState, .final)
        await waitUntil("onFinalizeComplete fired") { !completedSessions.isEmpty }
        XCTAssertEqual(completedSessions, [sid])
        XCTAssertFalse(harness.runtime.isFinalizing)

        let saved = try String(contentsOf: summaryURL(root: harness.markdownRoot, sessionId: sid), encoding: .utf8)
        XCTAssertEqual(saved, "## Decisions\n- Ship Friday.")
    }

    // MARK: - Session-token staleness: meeting B never receives meeting A's results

    func testOldSessionResultsDroppedAfterNewBegin_butStillPersistedToDisk() async throws {
        let db = try await makeTempDB()
        let router = GatedScriptedRouter(
            scripted: [LLMDelta(textIncrement: "MEETING-A-SUMMARY", isFinal: true)],
            gated: true
        )
        let titleGate = AsyncGate()
        let harness = makeHarness(
            database: db, router: router,
            generateTitle: { _ in
                await titleGate.wait()
                return "Generated Title For A"
            }
        )
        var completedSessions: [String] = []
        harness.runtime.onFinalizeComplete = { sid in completedSessions.append(sid) }

        let sidA = try await harness.runtime.activateSessionWithoutCapture(title: "Meeting 2026-06-09 10:00")
        addSpeech(harness.model)
        await harness.runtime.stop(detachedFinalize: true)

        // A new meeting begins on the SHARED live model while A's tail is parked
        // (title generation gated). Everything A produces from here on must skip
        // the UI and land in storage only.
        harness.model.begin(sessionId: "session_B", title: "Meeting B")
        await titleGate.open()
        await router.open()

        await waitUntil("meeting A finalisation completed") { completedSessions == [sidA] }

        XCTAssertEqual(harness.model.sessionId, "session_B")
        XCTAssertEqual(harness.model.title, "Meeting B", "A's generated title must not clobber B's")
        XCTAssertEqual(harness.model.liveSummary, "", "A's summary tokens must not stream into B")
        XCTAssertEqual(harness.model.summaryPhase, .idle, "B's phase must stay untouched by A's tail")
        XCTAssertNil(harness.model.regenerateSummary, "A's regenerate hook must not survive into B")

        // …but meeting A's summary still reached its own storage.
        let saved = try String(contentsOf: summaryURL(root: harness.markdownRoot, sessionId: sidA), encoding: .utf8)
        XCTAssertEqual(saved, "MEETING-A-SUMMARY")
    }

    // MARK: - Failure path: loud failed phase + working retry

    func testSummaryFailureSetsFailedPhase_andRetrySucceeds() async throws {
        let db = try await makeTempDB()
        let router = GatedScriptedRouter(
            scripted: [LLMDelta(textIncrement: "RECOVERED-SUMMARY", isFinal: true)],
            failFirst: 1
        )
        let harness = makeHarness(database: db, router: router)
        var completedSessions: [String] = []
        harness.runtime.onFinalizeComplete = { sid in completedSessions.append(sid) }

        let sid = try await harness.runtime.activateSessionWithoutCapture(title: "Meeting 2026-06-09 10:00")
        addSpeech(harness.model)

        // Full-await stop: returns only after the tail (which fails) completes.
        await harness.runtime.stop()

        guard case .failed(let message) = harness.model.summaryPhase else {
            XCTFail("Expected .failed phase, got \(harness.model.summaryPhase)")
            return
        }
        XCTAssertTrue(message.contains("Couldn't build the summary"), "Failure message must be user-facing")
        XCTAssertEqual(completedSessions, [sid], "Completion fires even when the summary failed")
        XCTAssertTrue(harness.model.canRegenerate, "The failed state must offer a retry")

        // Retry through the same affordance the view's Try-again button uses.
        await harness.model.regenerate()

        XCTAssertEqual(harness.model.summaryPhase, .done)
        XCTAssertEqual(harness.model.liveSummary, "RECOVERED-SUMMARY")
        let saved = try String(contentsOf: summaryURL(root: harness.markdownRoot, sessionId: sid), encoding: .utf8)
        XCTAssertEqual(saved, "RECOVERED-SUMMARY")
    }

    // MARK: - Double stop

    func testConcurrentDoubleStopRunsFinalisationOnce() async throws {
        let db = try await makeTempDB()
        let router = GatedScriptedRouter(
            scripted: [LLMDelta(textIncrement: "ONCE", isFinal: true)]
        )
        let harness = makeHarness(database: db, router: router)
        var completions = 0
        harness.runtime.onFinalizeComplete = { _ in completions += 1 }

        _ = try await harness.runtime.activateSessionWithoutCapture(title: "Meeting 2026-06-09 10:00")
        addSpeech(harness.model)

        async let first: Void = harness.runtime.stop()
        async let second: Void = harness.runtime.stop()
        _ = await (first, second)

        XCTAssertEqual(completions, 1, "Ending a meeting twice concurrently must finalise exactly once")
        XCTAssertEqual(harness.model.summaryPhase, .done)
        XCTAssertEqual(harness.model.liveSummary, "ONCE")
    }

    // MARK: - Title generation under the session guard

    func testGeneratedTitleAppliesToCurrentSession() async throws {
        let db = try await makeTempDB()
        let router = GatedScriptedRouter(
            scripted: [LLMDelta(textIncrement: "S", isFinal: true)]
        )
        let harness = makeHarness(
            database: db, router: router,
            generateTitle: { _ in "Quarterly Planning" }
        )
        _ = try await harness.runtime.activateSessionWithoutCapture(title: "Meeting 2026-06-09 10:00")
        addSpeech(harness.model)

        await harness.runtime.stop()

        XCTAssertEqual(harness.model.title, "Quarterly Planning")
    }

    func testGeneratedTitleNeverClobbersUserTypedTitle() async throws {
        let db = try await makeTempDB()
        let router = GatedScriptedRouter(
            scripted: [LLMDelta(textIncrement: "S", isFinal: true)]
        )
        let harness = makeHarness(
            database: db, router: router,
            generateTitle: { _ in "Model Title" }
        )
        _ = try await harness.runtime.activateSessionWithoutCapture(title: "Meeting 2026-06-09 10:00")
        addSpeech(harness.model)
        // The user renames the meeting before stopping — click-to-edit wins.
        harness.model.title = "My Own Title"

        await harness.runtime.stop()

        XCTAssertEqual(harness.model.title, "My Own Title")
    }

    // MARK: - Regenerate replaces rather than stacks

    func testRegenerateCancelsRunningGenerationInsteadOfStacking() async throws {
        let db = try await makeTempDB()
        let router = GatedScriptedRouter(
            scripted: [LLMDelta(textIncrement: "FINAL-TEXT", isFinal: true)],
            gated: true
        )
        let harness = makeHarness(database: db, router: router)

        _ = try await harness.runtime.activateSessionWithoutCapture(title: "Meeting 2026-06-09 10:00")
        addSpeech(harness.model)
        await harness.runtime.stop(detachedFinalize: true)
        await waitUntil("first generation streaming") { harness.model.summaryPhase == .generating }

        // Kick a regenerate while the first generation is parked on the gate,
        // then release everything. Only the replacement may write the UI.
        let regen = Task { await harness.model.regenerate(steer: "focus on decisions") }
        // Let the regenerate cancel + restart before opening the gate.
        try? await Task.sleep(nanoseconds: 100_000_000)
        await router.open()
        await regen.value

        await waitUntil("replacement generation done") { harness.model.summaryPhase == .done }
        XCTAssertEqual(harness.model.liveSummary, "FINAL-TEXT")
        let calls = await router.requests.count
        XCTAssertGreaterThanOrEqual(calls, 2, "The replacement issues its own model call")
    }

    // MARK: - No-session stop stays safe (legacy semantics)

    func testStopWithoutSessionLeavesPhaseIdle() async throws {
        let db = try await makeTempDB()
        let router = GatedScriptedRouter(scripted: [])
        let harness = makeHarness(database: db, router: router)

        await harness.runtime.stop(detachedFinalize: true)
        await harness.runtime.stop()

        XCTAssertEqual(harness.model.summaryPhase, .idle)
        XCTAssertFalse(harness.runtime.isFinalizing)
    }
}

// MARK: - Test doubles

/// A `ModelRoutingFacade` whose streams can be parked behind a gate (to hold a
/// generation mid-flight) and scripted to fail the first N calls (to drive the
/// failure → retry path).
private actor GatedScriptedRouter: ModelRoutingFacade {
    private let scripted: [LLMDelta]
    private var remainingFailures: Int
    private var gateOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [LLMRequest] = []

    init(scripted: [LLMDelta], failFirst: Int = 0, gated: Bool = false) {
        self.scripted = scripted
        self.remainingFailures = failFirst
        self.gateOpen = !gated
    }

    func open() {
        gateOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    private func waitForGate() async {
        guard !gateOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func beginCall(_ request: LLMRequest) -> Bool {
        requests.append(request)
        if remainingFailures > 0 {
            remainingFailures -= 1
            return false
        }
        return true
    }

    nonisolated func stream(
        _ request: LLMRequest, routeOverride: LLMRoute?
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let succeed = await self.beginCall(request)
                await self.waitForGate()
                guard succeed else {
                    continuation.finish(
                        throwing: TraceError.modelProviderFailed(
                            provider: "test",
                            underlying: TraceError.configInvalid(field: "x", reason: "boom")
                        ))
                    return
                }
                for delta in await self.deltas() {
                    continuation.yield(delta)
                }
                continuation.finish()
            }
        }
    }

    private func deltas() -> [LLMDelta] { scripted }
}

/// A one-shot async gate for parking injected closures (e.g. title generation)
/// until the test releases them.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
