import Foundation
import XCTest
import os

@testable import CoachModule
@testable import SharedCore

// MARK: - Test doubles

/// Controllable clock for the listener's cadence/spacing decisions.
private final class TestClock: @unchecked Sendable {
    private let box: OSAllocatedUnfairLock<Date>
    init(_ initial: Date = Date(timeIntervalSince1970: 1_000_000)) {
        box = OSAllocatedUnfairLock(initialState: initial)
    }
    var now: Date { box.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { box.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// A reusable async gate: callers block in `wait()` until `open()`.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
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

private struct ScriptedFailure: Error, CustomStringConvertible {
    let description = "scripted model failure"
}

/// A scripted `ModelRoutingFacade`: replays a fixed list of replies/failures (then
/// a default reply), records every request, and can block each call on a gate so
/// tests hold a check in flight deterministically.
private final class ScriptedRouter: ModelRoutingFacade, @unchecked Sendable {
    enum Step {
        case reply(String)
        case failure
    }

    private struct State {
        var steps: [Step]
        var requests: [LLMRequest] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    let defaultReply: String
    /// When set, every call waits on the gate before replying.
    let gate: AsyncGate?

    init(steps: [Step] = [], defaultReply: String = #"{"action":"silence"}"#, gate: AsyncGate? = nil) {
        self.state = OSAllocatedUnfairLock(initialState: State(steps: steps))
        self.defaultReply = defaultReply
        self.gate = gate
    }

    var requests: [LLMRequest] { state.withLock { $0.requests } }
    var callCount: Int { state.withLock { $0.requests.count } }

    func stream(_ request: LLMRequest, routeOverride: LLMRoute?) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.gate?.wait()
                let step: Step = self.state.withLock { state in
                    state.requests.append(request)
                    return state.steps.isEmpty ? .reply(self.defaultReply) : state.steps.removeFirst()
                }
                switch step {
                case .reply(let text):
                    continuation.yield(LLMDelta(textIncrement: text, isFinal: true))
                    continuation.finish()
                case .failure:
                    continuation.finish(throwing: ScriptedFailure())
                }
            }
        }
    }
}

/// A scripted retriever: fixed hits or a scripted error, recording queries/scopes.
private final class ScriptedRetriever: CoachRetrieving, @unchecked Sendable {
    private struct State {
        var hits: [VectorSearch.Hit]
        var failing: Bool
        var queries: [String] = []
        var scopes: [String?] = []
    }
    private let state: OSAllocatedUnfairLock<State>

    init(hits: [VectorSearch.Hit] = [], failing: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(hits: hits, failing: failing))
    }

    var queries: [String] { state.withLock { $0.queries } }
    var scopes: [String?] { state.withLock { $0.scopes } }
    func setFailing(_ failing: Bool) { state.withLock { $0.failing = failing } }

    func setProjectScope(_ projectID: String?) async {
        state.withLock { $0.scopes.append(projectID) }
    }

    func retrieve(query: String, k: Int) async throws -> [VectorSearch.Hit] {
        let (hits, failing): ([VectorSearch.Hit], Bool) = state.withLock {
            $0.queries.append(query)
            return ($0.hits, $0.failing)
        }
        if failing { throw ScriptedFailure() }
        return hits
    }
}

/// Collects listener events for assertions.
private actor EventCollector {
    private(set) var events: [CoachListenerEvent] = []
    func append(_ event: CoachListenerEvent) { events.append(event) }

    var surfaced: [CoachCard] {
        events.compactMap { if case .surfaced(let card) = $0 { return card } else { return nil } }
    }
    var withheld: [(CoachCard, CoachWithholdReason)] {
        events.compactMap { if case .withheld(let card, let reason) = $0 { return (card, reason) } else { return nil } }
    }
}

/// Collects health events off the listener's stream.
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

private func cardReply(
    kind: String = "answer", title: String = "Capital of Spain",
    body: String = "Madrid is the capital of Spain.", grounding: String = ""
) -> String {
    """
    {"action":"card","kind":"\(kind)","title":"\(title)","body":"\(body)","grounding":"\(grounding)"}
    """
}

private func makeHit(text: String, file: String = "notes.md", crumb: String = "Notes") -> VectorSearch.Hit {
    VectorSearch.Hit(
        chunk: KbChunk(sourceFile: file, breadcrumb: crumb, text: text, sourceSha256: "h"),
        score: 0.8
    )
}

// MARK: - Tests

final class CoachListenerTests: XCTestCase {

    private func makeListener(
        router: ScriptedRouter,
        retriever: ScriptedRetriever = ScriptedRetriever(),
        config: CoachConfig = CoachConfig(),
        clock: TestClock,
        collector: EventCollector
    ) -> CoachListener {
        CoachListener(
            config: config,
            router: router,
            retriever: retriever,
            now: { clock.now },
            onEvent: { event in await collector.append(event) }
        )
    }

    // MARK: Surfacing

    /// THE clarified product rule: a question with NO knowledge-base hits must
    /// still yield an answer card — the coach answers from general knowledge,
    /// with an empty grounding field. No code gate suppresses ungrounded answers.
    func testQuestionWithNoKbHitsStillYieldsAnswerCard() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [.reply(cardReply())])
        let retriever = ScriptedRetriever(hits: [])  // nothing in the KB
        let listener = makeListener(router: router, retriever: retriever, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "What is the capital of Spain again")
        await listener.tick()

        let surfaced = await collector.surfaced
        XCTAssertEqual(surfaced.count, 1, "an ungrounded general-knowledge answer must surface")
        XCTAssertEqual(surfaced.first?.kind, .answer)
        XCTAssertEqual(surfaced.first?.body, "Madrid is the capital of Spain.")
        XCTAssertEqual(surfaced.first?.grounding, "", "general knowledge carries no grounding quote")
        // And the prompt explicitly permits it.
        XCTAssertTrue(
            CoachListener.systemPrompt(intent: nil).contains("general knowledge is fine"),
            "the system prompt must explicitly allow general-knowledge answers")
    }

    /// Grounded card: the grounding quote rides through to the surfaced card.
    func testGroundedCardCarriesQuote() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(cardReply(kind: "recall", title: "Budget", body: "You agreed £40k.", grounding: "Budget cap £40k"))
        ])
        let listener = makeListener(
            router: router, retriever: ScriptedRetriever(hits: [makeHit(text: "Budget cap £40k")]),
            clock: clock, collector: collector)

        await listener.note(speaker: "You", text: "Remind me what we agreed on budget")
        await listener.tick()

        let surfaced = await collector.surfaced
        XCTAssertEqual(surfaced.first?.kind, .recall)
        XCTAssertEqual(surfaced.first?.grounding, "Budget cap £40k")
        XCTAssertTrue(surfaced.first?.isGrounded == true)
    }

    /// Silence is silence: no events, no cards.
    func testSilenceDecisionProducesNothing() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter()  // default reply is silence
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "We shipped the release on Tuesday.")
        await listener.tick()

        let events = await collector.events
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(router.callCount, 1)
    }

    // MARK: Request content

    /// The check request carries the transcript verbatim — including non-English
    /// text, unmangled — plus the retrieved snippets and the already-shown cards.
    func testRequestCarriesNonEnglishTranscriptUnmangled() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter()
        let listener = makeListener(
            router: router, retriever: ScriptedRetriever(hits: [makeHit(text: "El plural de luz es luces.")]),
            clock: clock, collector: collector)

        let spanish = "¿Cuál es la capital de Francia?"
        await listener.note(speaker: "Profesora", text: spanish)
        let called = await waitUntil { router.callCount >= 1 }  // "?" fast-path fires the check itself
        XCTAssertTrue(called)

        let user = router.requests.first?.messages.last?.content ?? ""
        XCTAssertTrue(user.contains("Profesora: \(spanish)"), "non-English transcript must reach the model verbatim")
        XCTAssertTrue(user.contains("El plural de luz es luces."), "retrieved snippets ride along")
        // No language assumptions: the prompt instructs, it doesn't filter.
        XCTAssertTrue(CoachListener.systemPrompt(intent: nil).contains("any language"))
    }

    /// Repeat suppression is prompt-borne: previously shown cards are included
    /// in the next request.
    func testShownCardsIncludedInNextRequest() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [.reply(cardReply(title: "Pricing question"))])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "What does the annual pricing look like")
        await listener.tick()
        XCTAssertEqual(router.callCount, 1)

        await listener.note(speaker: "Sarah", text: "And how does onboarding work")
        clock.advance(30)
        await listener.tick()
        XCTAssertEqual(router.callCount, 2)
        let secondRequest = router.requests[1].messages.last?.content ?? ""
        XCTAssertTrue(
            secondRequest.contains("Pricing question"),
            "the previously shown card must be listed for repeat suppression")
        XCTAssertTrue(secondRequest.contains("CARDS ALREADY SHOWN"))
    }

    // MARK: Cadence, single-flight, coalescing

    /// No new content → no check. New content but cadence not elapsed → no check.
    func testCadenceGate() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter()
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.tick()
        XCTAssertEqual(router.callCount, 0, "no content yet — no check")

        await listener.note(speaker: "Sarah", text: "Let me walk you through the plan.")
        await listener.tick()
        XCTAssertEqual(router.callCount, 1, "first check runs immediately on new content")

        await listener.note(speaker: "Sarah", text: "There are three phases in total.")
        clock.advance(5)  // < cadence (20s)
        await listener.tick()
        XCTAssertEqual(router.callCount, 1, "cadence not elapsed — no second check")

        clock.advance(20)
        await listener.tick()
        XCTAssertEqual(router.callCount, 2)
    }

    /// A bad persisted cadence clamps to the floor (≥10s).
    func testCadenceClampsToFloor() async {
        XCTAssertEqual(CoachConfig(checkCadenceSeconds: 3).effectiveCheckCadenceSeconds, 10)
        XCTAssertEqual(CoachConfig(checkCadenceSeconds: 45).effectiveCheckCadenceSeconds, 45)
    }

    /// Single-flight: a second tick during an in-flight check does nothing; the
    /// content that arrived mid-check coalesces into the NEXT check.
    func testSingleFlightAndCoalescing() async {
        let clock = TestClock()
        let collector = EventCollector()
        let gate = AsyncGate()
        let router = ScriptedRouter(gate: gate)
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "First remark before the check.")
        let first = Task { await listener.tick() }
        let started = await waitUntil { await gate.arrivals == 1 }
        XCTAssertTrue(started, "first check must reach the model")

        // Content arrives while the check is in flight; a concurrent tick must
        // NOT start a second model call.
        await listener.note(speaker: "Sarah", text: "Second remark during the check.")
        clock.advance(60)
        await listener.tick()
        let arrivalsDuringFlight = await gate.arrivals
        XCTAssertEqual(arrivalsDuringFlight, 1, "single-flight: no concurrent second check")

        await gate.open()
        await first.value
        XCTAssertEqual(router.callCount, 1)

        // The mid-check content is still pending — the next eligible tick runs
        // a check that includes it.
        let pending = await listener.hasPendingContent
        XCTAssertTrue(pending, "mid-check content must coalesce into the next check")
        clock.advance(60)
        await listener.tick()
        XCTAssertEqual(router.callCount, 2)
        let request = router.requests[1].messages.last?.content ?? ""
        XCTAssertTrue(request.contains("Second remark during the check."))
    }

    /// The question fast-path advances the next check without waiting out the
    /// cadence — timing only; it blocks nothing. (Subject only to the 8-second
    /// floor since the previous check's start, covered separately below.)
    func testQuestionMarkTriggersImmediateCheck() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter()
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "Here is some background context.")
        await listener.tick()
        XCTAssertEqual(router.callCount, 1)

        // Past the 8s fast-path floor but well inside the 20s cadence: the
        // cadence gate alone would refuse. The trailing question mark must
        // jump the queue (its own spawned tick).
        clock.advance(10)
        await listener.note(speaker: "Sarah", text: "What would this cost us per seat?")
        let fastChecked = await waitUntil { router.callCount >= 2 }
        XCTAssertTrue(fastChecked, "a question must advance the next check immediately")

        // Full-width (CJK) question marks count too.
        XCTAssertTrue(CoachListener.endsWithQuestionMark("这个多少钱？"))
        XCTAssertTrue(CoachListener.endsWithQuestionMark("How much?"))
        XCTAssertFalse(CoachListener.endsWithQuestionMark("No question here."))
    }

    /// The fast-path floor: a "?" utterance within 8 seconds of the previous
    /// check's start does NOT start a check — the content stays pending and the
    /// normal cadence covers it (nothing is lost). On question-dense real
    /// lessons the unfloored fast-path ran a paid check every ~16 seconds.
    func testFastPathFloorDefersButContentNotLost() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter()
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Lucía", text: "Vamos a empezar con el pretérito.")
        await listener.tick()
        XCTAssertEqual(router.callCount, 1)

        // 3s after the check started: inside the floor. No fast check fires —
        // not even a spawned tick — but the question is marked pending.
        clock.advance(3)
        await listener.note(speaker: "Lucía", text: "¿Qué hiciste el fin de semana pasado?")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(router.callCount, 1, "a question inside the floor must not start a check")
        let pending = await listener.hasPendingContent
        XCTAssertTrue(pending, "the deferred question stays pending for the next cadence check")

        // The normal cadence picks it up — the question reaches the model.
        clock.advance(17)  // 20s since the first check's start
        await listener.tick()
        XCTAssertEqual(router.callCount, 2, "the next cadence check covers the deferred question")
        let request = router.requests[1].messages.last?.content ?? ""
        XCTAssertTrue(request.contains("¿Qué hiciste el fin de semana pasado?"), "the deferred content is not lost")

        // Once the floor has elapsed since the latest check's start, the
        // fast-path fires again as before.
        clock.advance(9)
        await listener.note(speaker: "Lucía", text: "¿Y el domingo?")
        let fastChecked = await waitUntil { router.callCount >= 3 }
        XCTAssertTrue(fastChecked, "past the floor, a question advances the next check immediately")
    }

    // MARK: Budget (rolling window) + spacing gates

    /// Inside one trailing window the budget still withholds and reports: with
    /// an allowance of 1, a second card sixty seconds later (same 15-minute
    /// window) is held back as budget-exhausted, loudly.
    func testBudgetWithholdsAndReportsWithinWindow() async {
        let clock = TestClock()
        let collector = EventCollector()
        // Distinct bodies: the duplicate filter must not pre-empt the budget gate.
        let router = ScriptedRouter(steps: [
            .reply(cardReply(title: "First", body: "Annual pricing is per seat.")),
            .reply(cardReply(title: "Second", body: "Support SLAs run on business hours.")),
        ])
        var config = CoachConfig()
        config.surfaceBudget = 1
        let listener = makeListener(router: router, config: config, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "What is the annual price")
        await listener.tick()
        await listener.note(speaker: "Sarah", text: "And what about support SLAs")
        clock.advance(60)  // well past cadence AND spacing, inside the window — only the budget gates
        await listener.tick()

        let surfaced = await collector.surfaced
        let withheld = await collector.withheld
        XCTAssertEqual(surfaced.map(\.title), ["First"])
        XCTAssertEqual(withheld.count, 1)
        XCTAssertEqual(withheld.first?.0.title, "Second")
        XCTAssertEqual(withheld.first?.1, .budgetExhausted)
    }

    /// The budget is a ROLLING allowance, not a lifetime cap: once the window
    /// slides past an earlier card, the allowance refills and a new card
    /// surfaces — the lifetime total exceeds what the old per-meeting cap
    /// would ever have allowed.
    func testRollingBudgetAdmitsAgainAfterWindowSlides() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(cardReply(title: "First", body: "Annual pricing is per seat.")),
            .reply(cardReply(title: "Second", body: "Support SLAs run on business hours.")),
            .reply(cardReply(title: "Third", body: "Onboarding takes about two weeks.")),
        ])
        var config = CoachConfig()
        config.surfaceBudget = 1  // window stays the 15-minute default
        let listener = makeListener(router: router, config: config, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "What is the annual price")
        await listener.tick()  // "First" surfaces, spending the window's whole allowance

        await listener.note(speaker: "Sarah", text: "And what about support SLAs")
        clock.advance(60)  // inside the window → withheld
        await listener.tick()

        await listener.note(speaker: "Sarah", text: "And the onboarding timeline")
        clock.advance(15 * 60)  // the window has slid past "First" → allowance refilled
        await listener.tick()

        let surfaced = await collector.surfaced
        let withheld = await collector.withheld
        XCTAssertEqual(surfaced.map(\.title), ["First", "Third"], "the window sliding readmits automatic cards")
        XCTAssertEqual(withheld.map(\.1), [.budgetExhausted])
        XCTAssertEqual(
            surfaced.count, 2,
            "the lifetime total exceeds the old per-meeting cap (budget 1) — the budget no longer starves long meetings")
    }

    /// A long meeting keeps earning cards window after window: with an
    /// allowance of 2 per 15 minutes, three windows yield six cards — far past
    /// what the old lifetime cap (2) would have allowed.
    func testLongMeetingLifetimeTotalExceedsOldCap() async {
        let clock = TestClock()
        let collector = EventCollector()
        // Six distinct cards (titles AND bodies — the duplicate filter must not interfere).
        let router = ScriptedRouter(steps: [
            .reply(cardReply(title: "Pricing", body: "Annual pricing is charged per seat.")),
            .reply(cardReply(title: "Support", body: "Support hours run nine to five on weekdays.")),
            .reply(cardReply(title: "Onboarding", body: "Onboarding takes about two weeks end to end.")),
            .reply(cardReply(title: "Renewal", body: "The renewal lands in March with ninety days' notice.")),
            .reply(cardReply(title: "Discounts", body: "Volume discounts start at forty seats.")),
            .reply(cardReply(title: "Security", body: "The security review needs three weeks' lead time.")),
        ])
        var config = CoachConfig()
        config.surfaceBudget = 2  // window stays the 15-minute default
        let listener = makeListener(router: router, config: config, clock: clock, collector: collector)

        // Three windows; two well-spaced cards in each.
        for pair in 0..<3 {
            await listener.note(speaker: "Sarah", text: "Window \(pair) first question")
            clock.advance(16 * 60)  // a fresh window — earlier cards have slid out
            await listener.tick()
            await listener.note(speaker: "Sarah", text: "Window \(pair) second question")
            clock.advance(30)  // past cadence and spacing, same window
            await listener.tick()
        }

        let surfaced = await collector.surfaced
        let withheld = await collector.withheld
        XCTAssertEqual(surfaced.count, 6, "every window's allowance is honoured — got \(surfaced.map(\.title))")
        XCTAssertTrue(withheld.isEmpty, "nothing should be withheld — got \(withheld.map(\.1))")
        XCTAssertGreaterThan(
            surfaced.count, config.surfaceBudget,
            "the lifetime total exceeds the old per-meeting cap")
    }

    func testSpacingWithholdsThenAllows() async {
        let clock = TestClock()
        let collector = EventCollector()
        // Distinct bodies: the duplicate filter must not pre-empt the spacing gate.
        let router = ScriptedRouter(steps: [
            .reply(cardReply(title: "First", body: "Annual pricing is per seat.")),
            .reply(cardReply(title: "TooSoon", body: "SLAs cover response times only.")),
            .reply(cardReply(title: "Later", body: "Onboarding takes about two weeks.")),
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "What is the annual price")
        await listener.tick()
        await listener.note(speaker: "Sarah", text: "And what about SLAs")
        clock.advance(20)  // ≥ cadence, < 25s card spacing
        await listener.tick()
        await listener.note(speaker: "Sarah", text: "And the onboarding timeline")
        clock.advance(20)  // now 40s since the surfaced card
        await listener.tick()

        let surfaced = await collector.surfaced
        let withheld = await collector.withheld
        XCTAssertEqual(surfaced.map(\.title), ["First", "Later"])
        XCTAssertEqual(withheld.map(\.1), [.tooSoon])
    }

    // MARK: Manual asks

    /// Manual checks bypass cadence, budget and spacing, and always surface.
    func testManualBypassesBudgetAndSpacing() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(cardReply(title: "Auto")), .reply(cardReply(kind: "suggestion", title: "Manual", body: "Say this.")),
        ])
        var config = CoachConfig()
        config.surfaceBudget = 1
        let listener = makeListener(router: router, config: config, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "What is the annual price")
        await listener.tick()  // spends the whole budget, sets the spacing clock

        let card = try? await listener.manualCheck(intent: .soundSmart)
        XCTAssertEqual(card?.title, "Manual")
        XCTAssertEqual(card?.kind, .suggestion)
        let surfaced = await collector.surfaced
        XCTAssertEqual(surfaced.map(\.title), ["Auto", "Manual"], "manual cards surface despite spent budget + spacing")
        // The directive rides the system prompt.
        let system = router.requests[1].messages.first?.content ?? ""
        XCTAssertTrue(system.contains("Sound smart"))
        XCTAssertTrue(system.contains("Never reply with silence"))
    }

    /// A manual ask never ends in silent nothing: model silence → a stated
    /// inability card; garbage → a stated unusable-reply card. Health flags
    /// only once the contract-failure streak reaches the threshold.
    func testManualAlwaysProducesACard() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(#"{"action":"silence"}"#),
            .reply("definitely not json"), .reply("still not json"), .reply("nope"),
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)
        let health = HealthEventCollector()
        let stream = await listener.healthEvents()
        let pump = Task { for await event in stream { await health.append(event) } }
        defer { pump.cancel() }

        await listener.note(speaker: "Sarah", text: "Walk me through the pricing again.")
        let silent = try? await listener.manualCheck(intent: .answer)
        XCTAssertNotNil(silent)
        XCTAssertFalse(silent?.body.isEmpty ?? true, "silence on a manual ask becomes a stated inability")

        let garbage = try? await listener.manualCheck(intent: .answer)
        XCTAssertNotNil(garbage)
        XCTAssertTrue(garbage?.body.contains("couldn't be read") ?? false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let afterOne = await health.events
        XCTAssertTrue(afterOne.isEmpty, "one contract failure must NOT flap the health banner")

        _ = try? await listener.manualCheck(intent: .answer)
        _ = try? await listener.manualCheck(intent: .answer)
        let emitted = await waitUntil { await !health.events.isEmpty }
        XCTAssertTrue(emitted, "three consecutive unusable replies raise the health event")
    }

    /// A manual ask before anything was said states that plainly.
    func testManualWithEmptyTranscriptStatesInability() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter()
        let listener = makeListener(router: router, clock: clock, collector: collector)

        let card = try? await listener.manualCheck(intent: nil)
        XCTAssertTrue(card?.body.contains("Nothing has been said yet") ?? false)
        XCTAssertEqual(router.callCount, 0, "no model call without any transcript")
    }

    // MARK: Duplicate filter (code gate)

    /// Identical normalised title → withheld as a duplicate, reported loudly.
    /// (The bench showed "API Rate Limits" shipped twice under prompt-only
    /// no-repeat.)
    func testDuplicateTitleWithheldAndReported() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(cardReply(title: "API Rate Limits", body: "The cap is 120 requests per minute per key.")),
            .reply(cardReply(title: "api rate limits!", body: "Burst capacity reaches 200 for thirty seconds.")),
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Sam", text: "What did we cap the public API at")
        await listener.tick()
        await listener.note(speaker: "Marcus", text: "What's the rate limit on the public API now")
        clock.advance(60)
        await listener.tick()

        let surfaced = await collector.surfaced
        let withheld = await collector.withheld
        XCTAssertEqual(surfaced.map(\.title), ["API Rate Limits"])
        XCTAssertEqual(withheld.count, 1, "the repeat is withheld AND reported, never silent")
        XCTAssertEqual(withheld.first?.1, .duplicate)
    }

    /// Same fact under a new title → the body word-set overlap (Jaccard ≥ 0.6)
    /// catches it. (The bench showed the 18% discount restated under three
    /// different titles.)
    func testDuplicateBodyOverlapWithheldDespiteNewTitle() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(
                cardReply(
                    title: "Discount Calculation",
                    body: "Annual commitments of 40 seats or more qualify for an 18 per cent discount on the Aurora tier."
                )),
            .reply(
                cardReply(
                    title: "Discount Confirmation",
                    body: "The Aurora tier includes an 18 per cent discount for annual commitments of 40 seats or more."
                )),
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Marta", text: "What discount could you do on Aurora")
        await listener.tick()
        await listener.note(speaker: "Marta", text: "And for fifty seats annually")
        clock.advance(60)
        await listener.tick()

        let surfaced = await collector.surfaced
        let withheld = await collector.withheld
        XCTAssertEqual(surfaced.map(\.title), ["Discount Calculation"])
        XCTAssertEqual(withheld.map(\.1), [.duplicate], "a restated body is a duplicate even under a new title")
    }

    /// Manual asks are exempt from the duplicate filter entirely — the user
    /// explicitly re-asked.
    func testManualAskExemptFromDuplicateFilter() async {
        let clock = TestClock()
        let collector = EventCollector()
        let body = "The cap is 120 requests per minute per key."
        let router = ScriptedRouter(steps: [
            .reply(cardReply(title: "API Rate Limits", body: body)),
            .reply(cardReply(title: "API Rate Limits", body: body)),
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Sam", text: "What did we cap the public API at")
        await listener.tick()
        let manual = try? await listener.manualCheck(intent: .answer)

        XCTAssertEqual(manual?.title, "API Rate Limits")
        let surfaced = await collector.surfaced
        XCTAssertEqual(surfaced.count, 2, "an explicit re-ask surfaces even an identical card")
        let withheld = await collector.withheld
        XCTAssertTrue(withheld.isEmpty)
    }

    // MARK: Recall grounding enforcement (code gate)

    /// THE bench fabrication, verbatim: a recall claiming "data residency
    /// requirements" from the user's notes, with no grounding quote, in a
    /// meeting where nobody said any such thing. It must die — withheld as an
    /// unverifiable recall, loudly, never surfaced.
    func testFabricatedFrankfurtRecallIsDroppedAndReported() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(
                #"{"action":"recall","title":"Compliance requirements","body":"Remember that the Frankfurt region has specific data residency requirements that differ from the Dublin setup. Ensure we verify these before mirroring the infrastructure.","grounding":""}"#
            )
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(
            speaker: "Tom", text: "The infrastructure is the easy bit. We can mirror the Dublin setup almost one for one.")
        await listener.tick()

        let surfaced = await collector.surfaced
        XCTAssertTrue(surfaced.isEmpty, "a fabricated notes-claim must never surface — got \(surfaced)")
        let withheld = await collector.withheld
        XCTAssertEqual(withheld.count, 1)
        XCTAssertEqual(withheld.first?.1, .unverifiableRecall)
        XCTAssertEqual(withheld.first?.0.title, "Compliance requirements")
    }

    /// An ungrounded recall whose body makes no notes-claim survives — but only
    /// downgraded to a plain suggestion, with the (unverified) grounding cleared.
    func testUngroundedRecallWithNeutralBodyDowngradesToSuggestion() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(
                #"{"action":"recall","title":"Renewal date","body":"The renewal falls on the fourteenth of March, with ninety days' notice either way.","grounding":""}"#
            )
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Priya", text: "I can never keep their renewal deadline in my head.")
        await listener.tick()

        let surfaced = await collector.surfaced
        XCTAssertEqual(surfaced.count, 1)
        XCTAssertEqual(surfaced.first?.kind, .suggestion, "unverifiable recall downgrades, it never poses as recall")
        XCTAssertEqual(surfaced.first?.grounding, "", "an unverified quote must not display as grounding")
    }

    /// A recall whose quote IS verbatim in the supplied snippets survives as a
    /// recall — case and whitespace differences must not block the match.
    func testVerifiableRecallSurvivesCaseAndWhitespaceDifferences() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(
                cardReply(
                    kind: "recall", title: "Budget", body: "You agreed £40k in March.",
                    grounding: "budget CAP £40k agreed   in march"))
        ])
        let retriever = ScriptedRetriever(hits: [makeHit(text: "Budget cap £40k agreed\nin March, all-in.")])
        let listener = makeListener(router: router, retriever: retriever, clock: clock, collector: collector)

        await listener.note(speaker: "You", text: "Remind me what we agreed on budget")
        await listener.tick()

        let surfaced = await collector.surfaced
        XCTAssertEqual(surfaced.first?.kind, .recall)
        XCTAssertEqual(surfaced.first?.grounding, "budget CAP £40k agreed   in march", "the model's quote rides through")
    }

    /// A recall quote can also verify against the live transcript — recall of
    /// something said earlier in the meeting is legitimate.
    func testRecallQuoteVerifiableAgainstTranscript() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(
                cardReply(
                    kind: "recall", title: "Renewal deadline", body: "Dan confirmed the renewal is 14 March.",
                    grounding: "Renewal is the fourteenth of March"))
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(
            speaker: "Dan", text: "Renewal is the fourteenth of March, with ninety days' notice either way.")
        await listener.tick()

        let surfaced = await collector.surfaced
        XCTAssertEqual(surfaced.first?.kind, .recall)
        XCTAssertTrue(surfaced.first?.isGrounded == true)
    }

    /// Manual asks are NOT exempt from grounding enforcement: a fabricated
    /// notes-claim is replaced by a stated inability (never silent, never fake).
    func testManualFabricatedRecallStatesUnverifiable() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(
                #"{"action":"recall","title":"Data residency","body":"Per your notes, Frankfurt requires in-region storage.","grounding":"Frankfurt requires in-region storage"}"#
            )
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Tom", text: "We can mirror the Dublin setup almost one for one.")
        let card = try? await listener.manualCheck(intent: .factCheck)

        XCTAssertNotNil(card, "a manual ask always produces a card")
        XCTAssertTrue(
            card?.body.contains("couldn't be verified") ?? false,
            "the fabricated recall is replaced by a stated inability — got \(card?.body ?? "nil")")
    }

    /// On answer/suggestion cards an unverifiable quote doesn't kill the card —
    /// but it must not display as grounding.
    func testUnverifiableGroundingOnAnswerClearedButSurfaced() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(cardReply(kind: "answer", title: "GDPR", body: "GDPR became enforceable on 25 May 2018.", grounding: "this quote exists nowhere"))
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "You", text: "When did GDPR actually come into force")
        await listener.tick()

        let surfaced = await collector.surfaced
        XCTAssertEqual(surfaced.count, 1)
        XCTAssertEqual(surfaced.first?.kind, .answer)
        XCTAssertEqual(surfaced.first?.grounding, "", "a quote not found in the supplied material is cleared")
    }

    // MARK: Search round

    func testSearchRunsRetrievalAndOneFollowUp() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(#"{"action":"search","query":"renewal terms acme"}"#),
            .reply(cardReply(kind: "recall", title: "Renewal", body: "Acme renews in March.", grounding: "renews in March")),
        ])
        let retriever = ScriptedRetriever(hits: [makeHit(text: "Acme renews in March.")])
        let listener = makeListener(router: router, retriever: retriever, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "When does the Acme contract renew")
        await listener.tick()

        XCTAssertEqual(router.callCount, 2, "search costs exactly one follow-up call")
        XCTAssertEqual(retriever.queries.count, 2, "one ambient retrieval + one model-directed search")
        XCTAssertEqual(retriever.queries.last, "renewal terms acme")
        let followUp = router.requests[1].messages.last?.content ?? ""
        XCTAssertTrue(followUp.contains("SEARCH RESULTS"))
        XCTAssertTrue(followUp.contains("Acme renews in March."))
        let surfaced = await collector.surfaced
        XCTAssertEqual(surfaced.map(\.title), ["Renewal"])
    }

    /// A second search request is refused: max one round, then silence.
    func testSecondSearchRequestBecomesSilence() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply(#"{"action":"search","query":"one"}"#),
            .reply(#"{"action":"search","query":"two"}"#),
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "When does the Acme contract renew")
        await listener.tick()

        XCTAssertEqual(router.callCount, 2, "no third call — the search round is spent")
        let events = await collector.events
        XCTAssertTrue(events.isEmpty, "a chained search resolves to silence")
    }

    // MARK: Health (once per streak + recovery)

    func testModelFailureEmitsOncePerStreakThenRecovers() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [.failure, .failure, .failure])
        let listener = makeListener(router: router, clock: clock, collector: collector)
        let health = HealthEventCollector()
        let stream = await listener.healthEvents()
        let pump = Task { for await event in stream { await health.append(event) } }
        defer { pump.cancel() }

        for text in ["First question", "Second question", "Third question"] {
            await listener.note(speaker: "Sarah", text: text)
            clock.advance(60)
            await listener.tick()
        }
        await listener.note(speaker: "Sarah", text: "Fourth question")
        clock.advance(60)
        await listener.tick()  // default reply: silence → success

        let settled = await waitUntil { await health.events.count >= 2 }
        XCTAssertTrue(settled)
        let events = await health.events
        XCTAssertEqual(events.count, 2, "edge-triggered: one unavailable + one recovered — got \(events)")
        guard case .stageUnavailable(let stage, _) = events[0] else {
            return XCTFail("first event must be stageUnavailable, got \(events[0])")
        }
        XCTAssertEqual(stage, .listener)
        XCTAssertEqual(events[1], .stageRecovered(stage: .listener))
    }

    /// Contract failures (unparseable replies) are streak-gated: a flaky-format
    /// model must not flap the banner. Three consecutive unusable replies →
    /// exactly one `stageUnavailable`; the next usable reply → one recovery.
    func testGarbageRepliesFlagAfterThreeThenEmitOncePerStreak() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply("not json at all"),
            .reply(#"{"action":"card","kind":"nonsense","body":"x"}"#),
            .reply("{\"action\":\"suggestion\",\"title\":\"Truncated mid-bo"),
            .reply("more garbage"),
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)
        let health = HealthEventCollector()
        let stream = await listener.healthEvents()
        let pump = Task { for await event in stream { await health.append(event) } }
        defer { pump.cancel() }

        await listener.note(speaker: "Sarah", text: "First question")
        await listener.tick()
        await listener.note(speaker: "Sarah", text: "Second question")
        clock.advance(60)
        await listener.tick()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let early = await health.events
        XCTAssertTrue(early.isEmpty, "below the 3-streak threshold no contract failure may flag — got \(early)")

        await listener.note(speaker: "Sarah", text: "Third question")
        clock.advance(60)
        await listener.tick()
        let flagged = await waitUntil { await health.events.count >= 1 }
        XCTAssertTrue(flagged, "the third consecutive unusable reply must flag the listener stage")

        await listener.note(speaker: "Sarah", text: "Fourth question")
        clock.advance(60)
        await listener.tick()  // fourth garbage: same streak, no second event

        await listener.note(speaker: "Sarah", text: "Fifth question")
        clock.advance(60)
        await listener.tick()  // default reply: silence → success → recovery

        let settled = await waitUntil { await health.events.count >= 2 }
        XCTAssertTrue(settled)
        let events = await health.events
        XCTAssertEqual(events.count, 2, "edge-triggered: one unavailable + one recovered — got \(events)")
        guard case .stageUnavailable(let stage, _) = events[0] else {
            return XCTFail("first event must be stageUnavailable, got \(events[0])")
        }
        XCTAssertEqual(stage, .listener)
        XCTAssertEqual(events[1], .stageRecovered(stage: .listener))
        let surfaced = await collector.surfaced
        XCTAssertTrue(surfaced.isEmpty, "garbage is treated as silence, never surfaced")
    }

    /// A usable reply RESETS the contract-failure streak: two misses, a
    /// success, two more misses — never three consecutive, never an event.
    func testUsableReplyResetsContractFailureStreak() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [
            .reply("garbage one"), .reply("garbage two"),
            .reply(#"{"action":"silence"}"#),
            .reply("garbage three"), .reply("garbage four"),
        ])
        let listener = makeListener(router: router, clock: clock, collector: collector)
        let health = HealthEventCollector()
        let stream = await listener.healthEvents()
        let pump = Task { for await event in stream { await health.append(event) } }
        defer { pump.cancel() }

        for text in ["One", "Two", "Three", "Four", "Five"] {
            await listener.note(speaker: "Sarah", text: text)
            clock.advance(60)
            await listener.tick()
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await health.events
        XCTAssertTrue(events.isEmpty, "no 3-consecutive streak → no banner flap — got \(events)")
    }

    /// An outright refusal flags IMMEDIATELY — the model is actively declining,
    /// which is news the user needs, not format flakiness.
    func testRefusalFlagsImmediately() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [.reply("I cannot help with that request.")])
        let listener = makeListener(router: router, clock: clock, collector: collector)
        let health = HealthEventCollector()
        let stream = await listener.healthEvents()
        let pump = Task { for await event in stream { await health.append(event) } }
        defer { pump.cancel() }

        await listener.note(speaker: "Sarah", text: "What is our pricing")
        await listener.tick()

        let emitted = await waitUntil { await !health.events.isEmpty }
        XCTAssertTrue(emitted, "a refusal must flag the listener stage on the first miss")
        let surfaced = await collector.surfaced
        XCTAssertTrue(surfaced.isEmpty)
    }

    /// Retrieval failure degrades (the check still runs, model still called) and
    /// is surfaced once via the `.search` stage, recovering on success.
    func testRetrievalFailureDegradesAndRecovers() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter()
        let retriever = ScriptedRetriever(failing: true)
        let listener = makeListener(router: router, retriever: retriever, clock: clock, collector: collector)
        let health = HealthEventCollector()
        let stream = await listener.healthEvents()
        let pump = Task { for await event in stream { await health.append(event) } }
        defer { pump.cancel() }

        await listener.note(speaker: "Sarah", text: "What did we agree about budget")
        await listener.tick()
        XCTAssertEqual(router.callCount, 1, "a search failure must not kill the check")
        let request = router.requests.first?.messages.last?.content ?? ""
        XCTAssertTrue(request.contains("(none)"), "no snippets — stated, not faked")

        await listener.note(speaker: "Sarah", text: "And the timeline question")
        clock.advance(60)
        await listener.tick()

        retriever.setFailing(false)
        await listener.note(speaker: "Sarah", text: "One more question")
        clock.advance(60)
        await listener.tick()

        let settled = await waitUntil { await health.events.count >= 2 }
        XCTAssertTrue(settled)
        let events = await health.events
        XCTAssertEqual(events[0], .stageUnavailable(stage: .search, reason: "scripted model failure"))
        XCTAssertEqual(events[1], .stageRecovered(stage: .search))
    }

    // MARK: Pause (dismiss-for-meeting)

    func testPauseStopsAutoChecksButNotManual() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [.reply(cardReply(title: "Manual while paused"))])
        let listener = makeListener(router: router, clock: clock, collector: collector)

        await listener.setAutoChecksPaused(true)
        await listener.note(speaker: "Sarah", text: "What is the annual price")
        await listener.tick()
        XCTAssertEqual(router.callCount, 0, "paused: no automatic cloud calls")

        let card = try? await listener.manualCheck(intent: .answer)
        XCTAssertEqual(card?.title, "Manual while paused", "manual asks ignore the pause")

        await listener.setAutoChecksPaused(false)
        clock.advance(60)
        await listener.tick()
        XCTAssertEqual(router.callCount, 2, "resume: the pending content is checked")
    }

    // MARK: Compaction / cost bounding

    func testCompactionBoundsRecentBufferAndCarriesEarlierContext() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter()
        let listener = CoachListener(
            config: CoachConfig(),
            router: router,
            retriever: ScriptedRetriever(),
            maxRecentChars: 2_000,
            recentRetainChars: 1_000,
            maxEarlierChars: 3_000,
            now: { clock.now },
            onEvent: { event in await collector.append(event) }
        )

        let line = String(repeating: "all work and no play makes a long meeting ", count: 3)  // ~129 chars
        for index in 0..<80 {
            await listener.note(speaker: "Speaker \(index % 3)", text: "\(index) \(line)")
        }

        let recentChars = await listener.bufferedRecentChars
        XCTAssertLessThanOrEqual(recentChars, 2_000, "the verbatim buffer must stay bounded")
        let earlier = await listener.carriedEarlierContext
        XCTAssertFalse(earlier.isEmpty, "older lines move to the carried context, they are not dropped")
        XCTAssertLessThanOrEqual(earlier.count, 3_000 + CoachListener.trimMarker.count)
        XCTAssertTrue(earlier.hasPrefix(CoachListener.trimMarker), "overflow trims with an explicit marker")
        // The earliest surviving carried line is still verbatim transcript.
        XCTAssertTrue(earlier.contains("all work and no play"))
    }

    /// `beginMeeting` resets per-meeting state and scopes retrieval.
    func testBeginMeetingResetsStateAndScopesRetrieval() async {
        let clock = TestClock()
        let collector = EventCollector()
        let router = ScriptedRouter(steps: [.reply(cardReply(title: "Old meeting"))])
        let retriever = ScriptedRetriever()
        let listener = makeListener(router: router, retriever: retriever, clock: clock, collector: collector)

        await listener.note(speaker: "Sarah", text: "What is the annual price")
        await listener.tick()
        let before = await listener.surfacedCardCount
        XCTAssertEqual(before, 1)

        await listener.beginMeeting(projectID: "project-123")
        await listener.endMeeting()  // stop the cadence loop for determinism

        XCTAssertEqual(retriever.scopes.last, "project-123")
        let surfacedCount = await listener.surfacedCardCount
        XCTAssertEqual(surfacedCount, 0)
        let recentCount = await listener.bufferedRecentLineCount
        XCTAssertEqual(recentCount, 0)
        let titles = await listener.shownCardTitles
        XCTAssertTrue(titles.isEmpty, "shown-card history never bleeds into the next meeting")
    }
}

// MARK: - Decision parsing

final class CoachDecisionParsingTests: XCTestCase {
    func testParsesSilence() {
        XCTAssertEqual(CoachListener.parseDecision(#"{"action":"silence"}"#), .silence)
    }

    func testParsesCard() {
        let decision = CoachListener.parseDecision(
            #"{"action":"card","kind":"recall","title":"Budget","body":"You agreed £40k.","grounding":"cap £40k"}"#
        )
        XCTAssertEqual(decision, .card(kind: .recall, title: "Budget", body: "You agreed £40k.", grounding: "cap £40k"))
    }

    func testParsesCardWithMissingGrounding() {
        let decision = CoachListener.parseDecision(
            #"{"action":"card","kind":"answer","title":"T","body":"B"}"#
        )
        XCTAssertEqual(decision, .card(kind: .answer, title: "T", body: "B", grounding: ""))
    }

    func testParsesSearch() {
        XCTAssertEqual(
            CoachListener.parseDecision(#"{"action":"search","query":"renewal terms"}"#),
            .search(query: "renewal terms"))
    }

    func testToleratesCodeFences() {
        let fenced = """
            ```json
            {"action":"card","kind":"suggestion","title":"T","body":"Ask about scope.","grounding":""}
            ```
            """
        XCTAssertEqual(
            CoachListener.parseDecision(fenced),
            .card(kind: .suggestion, title: "T", body: "Ask about scope.", grounding: ""))
    }

    func testGarbageIsNil() {
        XCTAssertNil(CoachListener.parseDecision("not json"))
        XCTAssertNil(CoachListener.parseDecision(""))
        XCTAssertNil(CoachListener.parseDecision(#"{"action":"dance"}"#))
        XCTAssertNil(CoachListener.parseDecision(#"{"kind":"dance","title":"T","body":"B"}"#))
        XCTAssertNil(CoachListener.parseDecision(#"{"title":"T","body":"no decision word at all"}"#))
        // A reply truncated mid-JSON (no closing brace) is uninterpretable.
        XCTAssertNil(
            CoachListener.parseDecision(
                #"{"action":"suggestion","title":"Confirm next steps","body":"Suggest that you draft a quick email to Legal now to capture"#
            ))
    }

    func testUnknownKindIsNil() {
        XCTAssertNil(CoachListener.parseDecision(#"{"action":"card","kind":"pep-talk","title":"T","body":"B"}"#))
    }

    func testBlankBodyIsNil() {
        XCTAssertNil(CoachListener.parseDecision(#"{"action":"card","kind":"answer","title":"T","body":"  "}"#))
    }

    func testBlankSearchQueryIsNil() {
        XCTAssertNil(CoachListener.parseDecision(#"{"action":"search","query":"  "}"#))
    }

    func testRefusalBodyIsNil() {
        XCTAssertNil(
            CoachListener.parseDecision(
                #"{"action":"card","kind":"answer","title":"T","body":"I cannot help with that request."}"#))
    }

    func testRefusalDetector() {
        XCTAssertTrue(CoachListener.isLikelyRefusal("I'm sorry, but I cannot assist with this."))
        XCTAssertTrue(CoachListener.isLikelyRefusal("I am not able to provide that."))
        XCTAssertFalse(CoachListener.isLikelyRefusal("Madrid is the capital — confirm and move on."))
        XCTAssertFalse(CoachListener.isLikelyRefusal(""))
    }

    // MARK: Tolerant shapes — every near-miss seen verbatim in the coach bench
    // (BenchScenarios/coach/REPORT.md), which the strict parser discarded as
    // unusable. Each must now parse as a usable card.

    /// `action` carrying the card kind directly, no `kind` field — the dominant
    /// bench failure (54% of checks).
    func testActionAsKindSuggestionParses() {
        let decision = CoachListener.parseDecision(
            #"{"action":"suggestion","title":"Responder a Lucía","body":"Salúdala y dile que estás listo para empezar la práctica.","grounding":""}"#
        )
        XCTAssertEqual(
            decision,
            .card(
                kind: .suggestion, title: "Responder a Lucía",
                body: "Salúdala y dile que estás listo para empezar la práctica.", grounding: ""))
    }

    func testActionAsKindRecallParses() {
        let decision = CoachListener.parseDecision(
            #"{"action":"recall","title":"Enterprise API Exemption","body":"Remember that enterprise keys are exempt from the new rate limits until January.","grounding":""}"#
        )
        XCTAssertEqual(
            decision,
            .card(
                kind: .recall, title: "Enterprise API Exemption",
                body: "Remember that enterprise keys are exempt from the new rate limits until January.",
                grounding: ""))
    }

    /// Redundant `action` + `kind` both carrying the kind (bench: spanish-lesson,
    /// recall-from-notes, spam-resistance).
    func testActionAndKindBothPresentParses() {
        let decision = CoachListener.parseDecision(
            #"{"action":"suggestion","kind":"suggestion","title":"Support Rota","body":"You could offer to cover Ade's first weekend shift in November since they are away."}"#
        )
        XCTAssertEqual(
            decision,
            .card(
                kind: .suggestion, title: "Support Rota",
                body: "You could offer to cover Ade's first weekend shift in November since they are away.",
                grounding: ""))

        let answer = CoachListener.parseDecision(
            #"{"action":"answer","kind":"answer","title":"Payment Terms","body":"Our standard payment terms are 30 days.","grounding":""}"#
        )
        XCTAssertEqual(
            answer,
            .card(kind: .answer, title: "Payment Terms", body: "Our standard payment terms are 30 days.", grounding: ""))
    }

    /// Pretty-printed multi-line JSON (bench: moment-passed, spam-resistance).
    func testPrettyPrintedMultilineParses() {
        let pretty = """
            {
              "action": "suggestion",
              "title": "Usage Data",
              "body": "Offer to send the usage chart to Dan after the meeting so he can forward it to their procurement team.",
              "grounding": ""
            }
            """
        XCTAssertEqual(
            CoachListener.parseDecision(pretty),
            .card(
                kind: .suggestion, title: "Usage Data",
                body: "Offer to send the usage chart to Dan after the meeting so he can forward it to their procurement team.",
                grounding: ""))
    }

    /// Missing `grounding` key entirely (bench: casual-chitchat).
    func testMissingGroundingKeyParses() {
        let decision = CoachListener.parseDecision(
            #"{"action":"suggestion","title":"Share your evening","body":"Mention your plans or activity from last night to keep the conversation flowing while you wait for the client call."}"#
        )
        guard case .card(let kind, let title, _, let grounding) = decision else {
            return XCTFail("expected a card, got \(String(describing: decision))")
        }
        XCTAssertEqual(kind, .suggestion)
        XCTAssertEqual(title, "Share your evening")
        XCTAssertEqual(grounding, "")
    }

    /// The new flat contract: `kind` at top level, no `action` key.
    func testFlatKindShapeParses() {
        XCTAssertEqual(CoachListener.parseDecision(#"{"kind":"silence"}"#), .silence)
        XCTAssertEqual(
            CoachListener.parseDecision(#"{"kind":"search","query":"renewal terms"}"#),
            .search(query: "renewal terms"))
        XCTAssertEqual(
            CoachListener.parseDecision(#"{"kind":"answer","title":"T","body":"B","grounding":""}"#),
            .card(kind: .answer, title: "T", body: "B", grounding: ""))
        XCTAssertEqual(
            CoachListener.parseDecision(#"{"kind":"suggestion","title":"T","body":"Ask for the churn data."}"#),
            .card(kind: .suggestion, title: "T", body: "Ask for the churn data.", grounding: ""))
        XCTAssertEqual(
            CoachListener.parseDecision(#"{"kind":"recall","title":"T","body":"B","grounding":"quote"}"#),
            .card(kind: .recall, title: "T", body: "B", grounding: "quote"))
    }

    /// A missing/blank title derives one from the body's first clause instead
    /// of discarding a usable card.
    func testMissingTitleDerivesFromBodyFirstClause() {
        let decision = CoachListener.parseDecision(
            #"{"action":"suggestion","body":"Propose a phased rollout for Frankfurt, starting with a pilot to test the infrastructure."}"#
        )
        guard case .card(_, let title, let body, _) = decision else {
            return XCTFail("expected a card, got \(String(describing: decision))")
        }
        XCTAssertEqual(title, "Propose a phased rollout for Frankfurt")
        XCTAssertTrue(body.hasPrefix("Propose a phased rollout"))
    }

    func testDeriveTitleClampsOverlongFirstClause() {
        let longClause = String(repeating: "very ", count: 30) + "long suggestion body"
        let title = CoachListener.deriveTitle(fromBody: longClause)
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertTrue(title.hasSuffix("…"))

        XCTAssertEqual(CoachListener.deriveTitle(fromBody: "Ask about the churn data. It matters."), "Ask about the churn data")
    }
}

// MARK: - Duplicate filter units

final class CoachDuplicateFilterTests: XCTestCase {
    func testNormalisedTitleKeyStripsCaseAndPunctuation() {
        XCTAssertEqual(CoachListener.normalisedTitleKey("API Rate Limits"), "apiratelimits")
        XCTAssertEqual(CoachListener.normalisedTitleKey("  api — rate, limits!  "), "apiratelimits")
        XCTAssertEqual(CoachListener.normalisedTitleKey("…"), "")
    }

    func testJaccard() {
        let a = CoachListener.tokenSet("The cap is 120 requests per minute")
        XCTAssertEqual(CoachListener.jaccard(a, a), 1.0)
        XCTAssertEqual(CoachListener.jaccard(a, CoachListener.tokenSet("completely unrelated words here")), 0.0)
        XCTAssertEqual(CoachListener.jaccard(a, []), 0.0)
        XCTAssertEqual(CoachListener.jaccard([], []), 0.0)
    }

    func testIsDuplicateByTitleAndByBody() {
        let shown = [
            CoachCard(
                kind: .recall, title: "API Rate Limits",
                body: "The new public API rate limit is 120 requests per minute per key, with a burst capacity of 200 for 30 seconds.")
        ]
        // Same normalised title, different body.
        XCTAssertTrue(
            CoachListener.isDuplicate(
                title: "api rate limits", body: "Something else entirely about deadlines.", of: shown))
        // Different title, near-identical body.
        XCTAssertTrue(
            CoachListener.isDuplicate(
                title: "Public API Rate Limit",
                body: "The public API rate limit is 120 requests per minute per key, with a burst of 200 for 30 seconds.",
                of: shown))
        // Genuinely new content.
        XCTAssertFalse(
            CoachListener.isDuplicate(
                title: "Enterprise Exemption", body: "Enterprise keys are exempt until January.", of: shown))
        XCTAssertFalse(CoachListener.isDuplicate(title: "T", body: "B", of: []))
    }
}

// MARK: - Recall grounding units

final class CoachRecallGroundingTests: XCTestCase {
    func testGroundingVerifiableNormalisesCaseAndWhitespace() {
        let corpus = "Sam: the new public API rate limit went live this morning.\nNotes: Burst   up to 200."
        XCTAssertTrue(CoachListener.groundingIsVerifiable("Burst up to 200.", corpus: corpus))
        XCTAssertTrue(CoachListener.groundingIsVerifiable("THE NEW PUBLIC api rate limit", corpus: corpus))
        XCTAssertFalse(CoachListener.groundingIsVerifiable("a quote that is not there", corpus: corpus))
        XCTAssertFalse(CoachListener.groundingIsVerifiable("", corpus: corpus), "empty quote is unverifiable")
        XCTAssertFalse(CoachListener.groundingIsVerifiable("   ", corpus: corpus))
    }

    func testNotesClaimDetector() {
        XCTAssertTrue(CoachListener.makesNotesClaim("Remember that the Frankfurt region has specific requirements."))
        XCTAssertTrue(CoachListener.makesNotesClaim("Per your notes, the cap is £90k."))
        XCTAssertTrue(CoachListener.makesNotesClaim("According to your notes this slipped."))
        XCTAssertTrue(CoachListener.makesNotesClaim("You agreed to ship by Friday."))
        XCTAssertFalse(CoachListener.makesNotesClaim("GDPR became enforceable on 25 May 2018."))
        XCTAssertFalse(CoachListener.makesNotesClaim("Ask for the churn data behind that figure."))
    }

    func testResolveRecallKeepDowngradeDrop() {
        let corpus = "Dan: Renewal is the fourteenth of March, with ninety days' notice either way."
        XCTAssertEqual(
            CoachListener.resolveRecall(
                grounding: "renewal is the fourteenth of march", title: "Renewal", body: "It renews 14 March.",
                corpus: corpus),
            .keep)
        XCTAssertEqual(
            CoachListener.resolveRecall(
                grounding: "", title: "Renewal", body: "The renewal falls on the fourteenth of March.",
                corpus: corpus),
            .downgradeToSuggestion)
        XCTAssertEqual(
            CoachListener.resolveRecall(
                grounding: "", title: "Renewal", body: "Remember that the renewal is in March.", corpus: corpus),
            .drop)
        XCTAssertEqual(
            CoachListener.resolveRecall(
                grounding: "a fabricated quote", title: "Renewal", body: "Per your notes it renews in March.",
                corpus: corpus),
            .drop)
    }

    /// The bench's fabricated card, as a pure resolution check: empty quote +
    /// "Remember that…" body → drop, full stop.
    func testFrankfurtFabricationResolvesToDrop() {
        let corpus = """
            Priya: Morning both — let's sort the rollout plan for the Frankfurt region while we have the room.
            You: I want us to be careful on the compliance side before we commit to any dates.
            Tom: The infrastructure is the easy bit. We can mirror the Dublin setup almost one for one.
            """
        let resolution = CoachListener.resolveRecall(
            grounding: "",
            title: "Compliance requirements",
            body:
                "Remember that the Frankfurt region has specific data residency requirements that differ from the Dublin setup. Ensure we verify these before mirroring the infrastructure.",
            corpus: corpus)
        XCTAssertEqual(resolution, .drop)
    }
}
