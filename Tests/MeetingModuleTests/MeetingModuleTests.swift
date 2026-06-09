import Foundation
import XCTest

@testable import MeetingModule
@testable import SharedCore

// NOTE: The orphaned MeetingController / CaptureSession / MergerOrchestrator /
// MeetingDependencies layer (superseded by AppShell/Runtime/MeetingRuntime) was
// deleted along with its tests. What remains here are tests of the LIVE
// MeetingModule types: ConversationState extraction + digest, the routed
// conversation-state model, and auto-categorization.

final class MeetingModuleTests: XCTestCase {
    func testModuleNameIsCorrect() {
        XCTAssertEqual(MeetingModule.moduleName, "MeetingModule")
    }
}

struct ScriptedConversationModel: ConversationStateModeling {
    let json: String
    func generateConversationStateJSON(prompt: String) async throws -> String { json }
}

/// A `ConversationStateModeling` that records the prompt it was handed (so the
/// rolling tests can assert the prior state was carried into it) and returns a
/// scripted JSON state.
actor CapturingConversationModel: ConversationStateModeling {
    private let json: String
    private(set) var lastPrompt: String?
    init(json: String) { self.json = json }
    func generateConversationStateJSON(prompt: String) async throws -> String {
        lastPrompt = prompt
        return json
    }
}

final class ConversationStateExtractorTests: XCTestCase {
    func testExtractorParsesScriptedJSON() async throws {
        let router = ScriptedConversationModel(
            json: """
                {"topic":"pricing","summary":"Discussing annual plan","openQuestions":["discount"],"activeTensions":["budget"],"recentDecisions":["send proposal"]}
                """)
        let extractor = ConversationStateExtractor(model: router)
        let state = try await extractor.update(withRecentTranscript: "remote_1: What discount can you do?")
        XCTAssertEqual(state.topic, "pricing")
        XCTAssertEqual(state.openQuestions, ["discount"])
        XCTAssertEqual(state.recentDecisions, ["send proposal"])
    }

    func testExtractorThrowsOnMalformedJSON() async throws {
        let extractor = ConversationStateExtractor(model: ScriptedConversationModel(json: "not json"))
        do {
            _ = try await extractor.update(withRecentTranscript: "x")
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }

    // MARK: Rolling summary

    /// With no prior state, the prompt includes the transcript and marks that
    /// this is the first update (no carried-forward context).
    func testPromptMarksFirstUpdateWhenNoPriorState() {
        let prompt = ConversationStateExtractor.prompt(previous: .empty, transcript: "we talked about pricing")
        XCTAssertTrue(prompt.contains("we talked about pricing"))
        XCTAssertTrue(prompt.contains("none yet"), "first update should mark that there is no prior state")
    }

    /// The prior state is rendered into the prompt so the model can carry forward
    /// still-relevant context alongside the new transcript.
    func testPromptCarriesPriorStateForward() {
        let prior = ConversationStateModel(
            topic: "pricing", summary: "annual plan",
            openQuestions: ["volume discount"], activeTensions: [], recentDecisions: []
        )
        let prompt = ConversationStateExtractor.prompt(previous: prior, transcript: "now onto the timeline")
        XCTAssertTrue(prompt.contains("Topic: pricing"))
        XCTAssertTrue(prompt.contains("Open questions: volume discount"))
        XCTAssertTrue(prompt.contains("now onto the timeline"))
    }

    /// The running state is stateful: each update's result becomes the prior
    /// state fed into the next update's prompt.
    func testUpdateFeedsPriorStateIntoTheNextPrompt() async throws {
        let model = CapturingConversationModel(
            json: """
                {"topic":"pricing","summary":"annual plan","openQuestions":["volume discount"],"activeTensions":[],"recentDecisions":[]}
                """)
        let extractor = ConversationStateExtractor(model: model)
        _ = try await extractor.update(withRecentTranscript: "talked about pricing")
        _ = try await extractor.update(withRecentTranscript: "second window")
        let prompt = await model.lastPrompt
        XCTAssertEqual(
            prompt?.contains("Topic: pricing"), true, "second update must carry the first result forward as prior state"
        )
        XCTAssertEqual(prompt?.contains("second window"), true)
    }

    /// `reset()` drops the running state so a prior meeting never bleeds into the
    /// next one's prompts.
    func testResetClearsRunningStateSoItStopsCarryingForward() async throws {
        let model = CapturingConversationModel(
            json: """
                {"topic":"pricing","summary":"annual plan","openQuestions":["volume discount"],"activeTensions":[],"recentDecisions":[]}
                """)
        let extractor = ConversationStateExtractor(model: model)
        _ = try await extractor.update(withRecentTranscript: "talked about pricing")
        await extractor.reset()
        _ = try await extractor.update(withRecentTranscript: "fresh meeting")
        let prompt = await model.lastPrompt
        XCTAssertEqual(
            prompt?.contains("pricing"), false, "after reset, the prior meeting's state must not carry forward")
        XCTAssertEqual(prompt?.contains("none yet"), true)
        XCTAssertEqual(prompt?.contains("fresh meeting"), true)
    }
}

/// Captures the last `LLMRequest` so the conformer test can assert which task
/// class it routed through, and answers for `.appleFM` (the default route for
/// `.conversationStateExtractor`).
private actor CapturingLLMProvider: LLMProvider {
    nonisolated let kind: LLMProviderKind = .appleFM
    private let responseText: String
    private(set) var lastRequest: LLMRequest?
    init(responseText: String) { self.responseText = responseText }
    func generate(_ request: LLMRequest, route: LLMRoute) async throws -> LLMResponse {
        lastRequest = request
        return LLMResponse(
            text: responseText, finishReason: .stop, usage: .zero,
            provider: route.provider.rawValue, model: route.model
        )
    }
    nonisolated func stream(
        _ request: LLMRequest, route: LLMRoute
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class ConversationStateDigestTests: XCTestCase {
    /// An empty state renders to an empty string so it adds nothing to the coach
    /// router prompt (indistinguishable from "no state yet").
    func testEmptyStateProducesEmptyDigest() {
        XCTAssertEqual(ConversationStateModel.empty.digest, "")
    }

    /// A fully-populated state renders as labeled lines, lists joined by "; ".
    func testFullStateProducesLabeledMultilineDigest() {
        let model = ConversationStateModel(
            topic: "pricing",
            summary: "Discussing the annual plan",
            openQuestions: ["volume discount", "contract length"],
            activeTensions: ["budget"],
            recentDecisions: ["send proposal Friday"]
        )
        XCTAssertEqual(
            model.digest,
            """
            Topic: pricing
            Summary: Discussing the annual plan
            Open questions: volume discount; contract length
            Active tensions: budget
            Recent decisions: send proposal Friday
            """)
    }

    /// Empty fields are omitted entirely (no blank "Summary:" lines).
    func testDigestOmitsEmptyFields() {
        let model = ConversationStateModel(
            topic: "pricing", summary: "",
            openQuestions: [], activeTensions: [], recentDecisions: []
        )
        XCTAssertEqual(model.digest, "Topic: pricing")
    }

    /// End to end: the extractor's decoded model formats into the digest the
    /// coach orchestrator consumes.
    func testExtractorOutputFormatsIntoDigest() async throws {
        let model = ScriptedConversationModel(
            json: """
                {"topic":"pricing","summary":"Annual plan","openQuestions":["discount"],"activeTensions":[],"recentDecisions":["send proposal"]}
                """)
        let extractor = ConversationStateExtractor(model: model)
        let state = try await extractor.update(withRecentTranscript: "remote_1: what discount?")
        XCTAssertEqual(
            state.digest,
            """
            Topic: pricing
            Summary: Annual plan
            Open questions: discount
            Recent decisions: send proposal
            """)
    }
}

final class RoutedConversationStateModelTests: XCTestCase {
    /// The conformer must route through the `.conversationStateExtractor` task
    /// class (so the user's per-stage routing config — Apple FM, Ollama, or a
    /// cloud model — applies) and return the model's raw text verbatim for the
    /// extractor to decode.
    func testRoutesViaConversationStateTaskAndReturnsModelText() async throws {
        let json = #"{"topic":"x","summary":"","openQuestions":[],"activeTensions":[],"recentDecisions":[]}"#
        let provider = CapturingLLMProvider(responseText: json)
        let router = ModelRouter()
        await router.register(provider: provider)
        let model = RoutedConversationStateModel(router: router)

        let result = try await model.generateConversationStateJSON(prompt: "Transcript: hello")

        XCTAssertEqual(result, json)
        let task = await provider.lastRequest?.taskClass
        XCTAssertEqual(task, .conversationStateExtractor)
    }
}

struct StubSignalProvider: CategorizationSignalProviding {
    let signals: CategorizationSignals
    init(
        _ signals: CategorizationSignals = .init(
            regex: 0.5, attendee: 0.5, content: 0.5, recurring: 0.5, manualHistory: 0.5)
    ) {
        self.signals = signals
    }
    func signals(
        for meeting: MeetingCategorizationInput, project: ProjectCandidate
    ) async throws -> CategorizationSignals {
        signals
    }
}

extension MeetingCategorizationInput {
    static func fixture(manualOverride: Bool = false) -> MeetingCategorizationInput {
        MeetingCategorizationInput(
            manualOverride: manualOverride, transcriptPrefix: "",
            attendeeEmails: []
        )
    }
}

extension ProjectCandidate {
    static func fixture(name: String, id: UUID = UUID()) -> ProjectCandidate {
        ProjectCandidate(id: id, name: name)
    }
}

final class ProjectCategorizerTests: XCTestCase {
    func testWeightedScoreUsesFiveSignals() {
        let project = ProjectCandidate.fixture(name: "Optivise")
        let signals = CategorizationSignals(regex: 1, attendee: 0.8, content: 0.5, recurring: 0.5, manualHistory: 0)
        let result = ProjectCategorizer.score(project: project, signals: signals)
        XCTAssertEqual(result.confidence, 0.3 + 0.2 + 0.125 + 0.075, accuracy: 0.0001)
    }

    func testManualOverrideSkipsCategorization() async throws {
        let categorizer = ProjectCategorizer(signalProvider: StubSignalProvider())
        let result = try await categorizer.categorize(
            .fixture(manualOverride: true), projects: [.fixture(name: "A")]
        )
        XCTAssertEqual(result.bucket, .manualOverride)
        XCTAssertTrue(result.scores.isEmpty)
    }

    func testHighConfidenceAutoAssigns() async throws {
        let strong = CategorizationSignals(regex: 1, attendee: 1, content: 1, recurring: 1, manualHistory: 1)
        let categorizer = ProjectCategorizer(signalProvider: StubSignalProvider(strong))
        let result = try await categorizer.categorize(
            .fixture(), projects: [.fixture(name: "A")]
        )
        XCTAssertEqual(result.bucket, .autoAssign)
    }

    func testLowConfidenceFallsToInbox() async throws {
        let weak = CategorizationSignals(regex: 0, attendee: 0, content: 0.1, recurring: 0, manualHistory: 0)
        let categorizer = ProjectCategorizer(signalProvider: StubSignalProvider(weak))
        let result = try await categorizer.categorize(
            .fixture(), projects: [.fixture(name: "A")]
        )
        XCTAssertEqual(result.bucket, .inbox)
    }
}

actor StubCategorizationSink: CategorizationNotificationSink {
    var sentActions: [CategorizationAction] = []
    var sendCount = 0
    func send(title: String, body: String, actions: [CategorizationAction]) async throws {
        sentActions = actions
        sendCount += 1
    }
}

final class CategorizationNotifierTests: XCTestCase {
    func testAskUserResultSendsTopProjectActions() async throws {
        let sink = StubCategorizationSink()
        let notifier = CategorizationNotifier(sink: sink)
        let result = CategorizationResult(
            bucket: .askUser,
            scores: [
                .init(project: .fixture(name: "A"), confidence: 0.7),
                .init(project: .fixture(name: "B"), confidence: 0.6),
                .init(project: .fixture(name: "C"), confidence: 0.5),
                .init(project: .fixture(name: "D"), confidence: 0.4),
            ]
        )
        try await notifier.notifyIfNeeded(result: result, meetingTitle: "Call")
        let sent = await sink.sentActions
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent.map(\.title), ["A", "B", "C"])
    }

    func testAutoAssignDoesNotSend() async throws {
        let sink = StubCategorizationSink()
        let notifier = CategorizationNotifier(sink: sink)
        let result = CategorizationResult(
            bucket: .autoAssign,
            scores: [.init(project: .fixture(name: "X"), confidence: 0.9)]
        )
        try await notifier.notifyIfNeeded(result: result, meetingTitle: "Call")
        let count = await sink.sendCount
        XCTAssertEqual(count, 0)
    }
}
