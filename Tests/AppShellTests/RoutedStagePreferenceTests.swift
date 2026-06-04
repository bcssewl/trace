import SharedCore
import XCTest

@testable import AppShell

/// BAS-49 — the 6 hand-rolled per-task picker triads (dictation cleanup, meeting
/// notes, meeting title, auto-categorization, library Q&A, conversation state)
/// are generalized into one `LLMRouteStage` descriptor + `RoutedStagePreference`
/// value type + generalized `AppStateModel` accessors.
///
/// These tests pin the
/// behaviour that MUST stay identical after the refactor: the exact persisted
/// UserDefaults keys, the per-stage default providers, the `.deterministic`
/// coercion rules, the per-stage default-model logic (incl. the library-Q&A /
/// conversation-state cross-reference to the notes Ollama model), the
/// model-override clear rules, and the per-stage config-changed notification.
/// Every (providerKey, modelsKey) the legacy triads persisted to. The
/// generalized descriptor must reproduce these byte-for-byte or restored
/// preferences silently reset on upgrade. File-scope so the nonisolated XCTest
/// setUp/tearDown can clear them without an actor hop.
private let bas49LegacyKeys: [LLMRouteStage: (provider: String, models: String)] = [
    .dictationCleanup: ("app.trace.dictation.cleanupProvider", "app.trace.dictation.cleanupModels"),
    .meetingNotes: ("app.trace.meeting.notesProvider", "app.trace.meeting.notesModels"),
    .meetingTitle: ("app.trace.meeting.titleProvider", "app.trace.meeting.titleModels"),
    .meetingCategorization: ("app.trace.meeting.categorizationProvider", "app.trace.meeting.categorizationModels"),
    .libraryQA: ("app.trace.library.qaProvider", "app.trace.library.qaModels"),
    .conversationState: ("app.trace.coach.conversationStateProvider", "app.trace.coach.conversationStateModels"),
    .coachSmartRouting: ("app.trace.coach.smartRoutingProvider", "app.trace.coach.smartRoutingModels"),
    .coachCardContent: ("app.trace.coach.cardContentProvider", "app.trace.coach.cardContentModels"),
]

@MainActor
final class RoutedStagePreferenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        for (_, keys) in bas49LegacyKeys {
            UserDefaults.standard.removeObject(forKey: keys.provider)
            UserDefaults.standard.removeObject(forKey: keys.models)
        }
    }

    override func tearDown() {
        for (_, keys) in bas49LegacyKeys {
            UserDefaults.standard.removeObject(forKey: keys.provider)
            UserDefaults.standard.removeObject(forKey: keys.models)
        }
        super.tearDown()
    }

    private func persistedModels(_ key: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    // MARK: descriptor

    func testEveryTaskStageDefined() {
        // The stages cover every wired LLM task class (incl. the two coach stages
        // added in BAS-35).
        XCTAssertEqual(
            Set(LLMRouteStage.allCases),
            [
                .dictationCleanup, .meetingNotes, .meetingTitle,
                .meetingCategorization, .libraryQA, .conversationState,
                .coachSmartRouting, .coachCardContent,
            ])
    }

    func testDescriptorKeysMatchLegacy() {
        for stage in LLMRouteStage.allCases {
            let expected = bas49LegacyKeys[stage]!
            XCTAssertEqual(stage.providerKey, expected.provider, "providerKey for \(stage)")
            XCTAssertEqual(stage.modelsKey, expected.models, "modelsKey for \(stage)")
        }
    }

    func testMeetingNotesDrivesSummaryAndMerge() {
        XCTAssertEqual(Set(LLMRouteStage.meetingNotes.taskClasses), [.meetingSummary, .meetingAugmentedMerge])
        XCTAssertEqual(LLMRouteStage.dictationCleanup.taskClasses, [.dictationCleanup])
        XCTAssertEqual(LLMRouteStage.meetingTitle.taskClasses, [.titleGeneration])
        XCTAssertEqual(LLMRouteStage.meetingCategorization.taskClasses, [.projectCategorization])
        XCTAssertEqual(LLMRouteStage.libraryQA.taskClasses, [.libraryQA])
        XCTAssertEqual(LLMRouteStage.conversationState.taskClasses, [.conversationStateExtractor])
    }

    func testOfferedProviders() {
        // The always-on set is local-only. Every cloud provider — OpenRouter and
        // the connect cards (Anthropic / ChatGPT / MiniMax) — is added by
        // `everydayProviders(connected:)` only once its key/credential is present,
        // so an un-keyed cloud provider is never offered.
        XCTAssertEqual(LLMRouteStage.dictationCleanup.offeredProviders, [.deterministic, .appleFM, .ollama])
        XCTAssertEqual(LLMRouteStage.meetingNotes.offeredProviders, [.appleFM, .ollama])
        XCTAssertEqual(LLMRouteStage.conversationState.offeredProviders, [.appleFM, .ollama])
        XCTAssertEqual(LLMRouteStage.libraryQA.offeredProviders, [.ollama])
    }

    func testEverydayProvidersGatesOnConnection() {
        // No providers connected → only the always-on local base list. OpenRouter
        // is gated now too, so it's absent without a key.
        XCTAssertEqual(
            LLMRouteStage.meetingNotes.everydayProviders(connected: []),
            [.appleFM, .ollama]
        )
        // OpenRouter keyed → appended; it leads the cloud set (in
        // `ModelProvider.keyedCloudProviders` order: openRouter, anthropic,
        // minimax, chatgpt).
        XCTAssertEqual(
            LLMRouteStage.meetingNotes.everydayProviders(connected: [.openRouter]),
            [.appleFM, .ollama, .openRouter]
        )
        // OpenRouter + Anthropic + ChatGPT connected → appended in that order;
        // MiniMax stays hidden until connected.
        XCTAssertEqual(
            LLMRouteStage.meetingNotes.everydayProviders(connected: [.openRouter, .anthropic, .chatgpt]),
            [.appleFM, .ollama, .openRouter, .anthropic, .chatgpt]
        )
        // The bridge to the catalog is 1:1 by raw value for every LLM provider;
        // only `.deterministic` (the no-LLM fixer) has no catalog entry.
        XCTAssertEqual(DictationCleanupProvider.anthropic.modelProvider, .anthropic)
        XCTAssertEqual(DictationCleanupProvider.chatgpt.modelProvider, .chatgpt)
        XCTAssertEqual(DictationCleanupProvider.minimax.modelProvider, .minimax)
        XCTAssertEqual(DictationCleanupProvider.appleFM.modelProvider, .appleFM)
        XCTAssertEqual(DictationCleanupProvider.openRouter.modelProvider, .openRouter)
        XCTAssertNil(DictationCleanupProvider.deterministic.modelProvider)
    }

    func testConfigChangedNotificationPerStage() {
        XCTAssertEqual(LLMRouteStage.dictationCleanup.configChangedNotification, .traceDictationPrefsChanged)
        XCTAssertEqual(LLMRouteStage.meetingNotes.configChangedNotification, .traceMeetingConfigChanged)
        XCTAssertEqual(LLMRouteStage.meetingTitle.configChangedNotification, .traceMeetingConfigChanged)
        XCTAssertEqual(LLMRouteStage.meetingCategorization.configChangedNotification, .traceMeetingConfigChanged)
        XCTAssertEqual(LLMRouteStage.libraryQA.configChangedNotification, .traceLibraryQAConfigChanged)
        XCTAssertEqual(LLMRouteStage.conversationState.configChangedNotification, .traceConversationStateConfigChanged)
    }

    // MARK: default providers + coercion

    func testDefaultProvidersWhenUnset() {
        let state = AppStateModel()
        XCTAssertEqual(state.provider(for: .dictationCleanup), .deterministic)
        XCTAssertEqual(state.provider(for: .meetingNotes), .appleFM)
        XCTAssertEqual(state.provider(for: .meetingTitle), .appleFM)
        XCTAssertEqual(state.provider(for: .meetingCategorization), .appleFM)
        XCTAssertEqual(state.provider(for: .libraryQA), .ollama)
        XCTAssertEqual(state.provider(for: .conversationState), .appleFM)
    }

    func testDeterministicCoercionOnRestore() {
        // Persist `.deterministic` for every stage, then restore.
        for stage in LLMRouteStage.allCases {
            UserDefaults.standard.set(DictationCleanupProvider.deterministic.rawValue, forKey: stage.providerKey)
        }
        let state = AppStateModel()
        // Only dictation cleanup keeps `.deterministic` (it has a real no-LLM path).
        XCTAssertEqual(state.provider(for: .dictationCleanup), .deterministic)
        // Notes / title / categorization / conversation-state coerce to Apple FM.
        XCTAssertEqual(state.provider(for: .meetingNotes), .appleFM)
        XCTAssertEqual(state.provider(for: .meetingTitle), .appleFM)
        XCTAssertEqual(state.provider(for: .meetingCategorization), .appleFM)
        XCTAssertEqual(state.provider(for: .conversationState), .appleFM)
        // Library Q&A coerces to Ollama (needs a generative provider).
        XCTAssertEqual(state.provider(for: .libraryQA), .ollama)
    }

    func testRestoresPersistedProvider() {
        UserDefaults.standard.set(
            DictationCleanupProvider.ollama.rawValue, forKey: LLMRouteStage.meetingNotes.providerKey)
        let state = AppStateModel()
        XCTAssertEqual(state.provider(for: .meetingNotes), .ollama)
    }

    // MARK: setProvider persistence + notification

    func testSetProviderPersistsToLegacyKey() {
        let state = AppStateModel()
        state.setProvider(.openRouter, for: .libraryQA)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: LLMRouteStage.libraryQA.providerKey),
            DictationCleanupProvider.openRouter.rawValue
        )
    }

    func testSetProviderPostsStageNotification() {
        let state = AppStateModel()
        let exp = expectation(forNotification: .traceConversationStateConfigChanged, object: nil)
        state.setProvider(.ollama, for: .conversationState)
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: model defaults + override round-trip

    func testBaseDefaultModels() {
        let state = AppStateModel()
        XCTAssertEqual(state.model(for: .dictationCleanup, provider: .appleFM), "apple-fm-default")
        XCTAssertEqual(state.model(for: .dictationCleanup, provider: .ollama), "llama3.2")
        XCTAssertEqual(state.model(for: .dictationCleanup, provider: .openRouter), "google/gemini-3.1-flash-lite")
        XCTAssertEqual(state.model(for: .meetingNotes, provider: .ollama), "llama3.2")
        XCTAssertEqual(state.model(for: .meetingTitle, provider: .openRouter), "google/gemini-3.1-flash-lite")
    }

    func testLibraryQAAndConversationStateOpenRouterDefaultsDiffer() {
        let state = AppStateModel()
        XCTAssertEqual(state.model(for: .libraryQA, provider: .openRouter), "google/gemini-3.1-flash-lite")
        XCTAssertEqual(state.model(for: .conversationState, provider: .openRouter), "anthropic/claude-3.5-haiku")
    }

    func testLibraryQAOllamaDefaultTracksNotesOllamaModel() {
        let state = AppStateModel()
        // Default with no notes override is the base Ollama default.
        XCTAssertEqual(state.model(for: .libraryQA, provider: .ollama), "llama3.2")
        XCTAssertEqual(state.model(for: .conversationState, provider: .ollama), "llama3.2")
        // Changing the notes Ollama model flows through to Q&A + conversation state.
        state.setModel("qwen2.5", for: .meetingNotes, provider: .ollama)
        XCTAssertEqual(state.model(for: .libraryQA, provider: .ollama), "qwen2.5")
        XCTAssertEqual(state.model(for: .conversationState, provider: .ollama), "qwen2.5")
    }

    func testModelOverrideRoundTripAndClear() {
        let state = AppStateModel()
        state.setModel("openai/gpt-4o", for: .libraryQA, provider: .openRouter)
        XCTAssertEqual(state.model(for: .libraryQA, provider: .openRouter), "openai/gpt-4o")
        XCTAssertEqual(persistedModels(LLMRouteStage.libraryQA.modelsKey)["openRouter"], "openai/gpt-4o")
        // Blank clears back to the default.
        state.setModel("", for: .libraryQA, provider: .openRouter)
        XCTAssertEqual(state.model(for: .libraryQA, provider: .openRouter), "google/gemini-3.1-flash-lite")
        XCTAssertNil(persistedModels(LLMRouteStage.libraryQA.modelsKey)["openRouter"])
    }

    /// Cleanup-family setters also clear when the typed value equals the base
    /// default; library-Q&A / conversation-state setters keep it.
    ///
    /// This was a real
    /// behavioural difference between the legacy setters and must be preserved.
    func testCleanupClearsModelMatchingBaseDefault() {
        let state = AppStateModel()
        state.setModel("llama3.2", for: .dictationCleanup, provider: .ollama)  // == base default
        XCTAssertNil(
            persistedModels(LLMRouteStage.dictationCleanup.modelsKey)["ollama"],
            "cleanup-family removes an override equal to the base default")
        XCTAssertEqual(state.model(for: .dictationCleanup, provider: .ollama), "llama3.2")
    }

    func testLibraryQAKeepsModelMatchingBaseDefault() {
        let state = AppStateModel()
        state.setModel("llama3.2", for: .libraryQA, provider: .ollama)  // equals computed default
        XCTAssertEqual(
            persistedModels(LLMRouteStage.libraryQA.modelsKey)["ollama"], "llama3.2",
            "library-Q&A only clears on blank, never on default-match")
    }

    func testSetModelPostsStageNotification() {
        let state = AppStateModel()
        let exp = expectation(forNotification: .traceMeetingConfigChanged, object: nil)
        state.setModel("openai/gpt-4o", for: .meetingNotes, provider: .openRouter)
        wait(for: [exp], timeout: 1.0)
    }

    func testUnchangedModelSetIsNoOp() {
        let state = AppStateModel()
        state.setModel("openai/gpt-4o", for: .meetingTitle, provider: .openRouter)
        // Re-setting the same value must not post (matches the legacy `guard
        // next != models` short-circuit).
        let exp = expectation(forNotification: .traceMeetingConfigChanged, object: nil)
        exp.isInverted = true
        state.setModel("openai/gpt-4o", for: .meetingTitle, provider: .openRouter)  // same value
        wait(for: [exp], timeout: 0.3)
    }

    // MARK: legacy named forwarders stay in sync

    func testForwardersReflectGeneralizedAPI() {
        let state = AppStateModel()
        state.setProvider(.ollama, for: .dictationCleanup)
        XCTAssertEqual(state.dictationCleanupProvider, .ollama)
        state.dictationCleanupProvider = .openRouter
        XCTAssertEqual(state.provider(for: .dictationCleanup), .openRouter)

        state.setModel("qwen2.5", for: .dictationCleanup, provider: .ollama)
        XCTAssertEqual(state.cleanupModel(for: .ollama), "qwen2.5")
        state.setCleanupModel("mistral", for: .ollama)
        XCTAssertEqual(state.model(for: .dictationCleanup, provider: .ollama), "mistral")

        state.meetingNotesProvider = .ollama
        XCTAssertEqual(state.provider(for: .meetingNotes), .ollama)
        XCTAssertEqual(state.meetingNotesModel(for: .ollama), state.model(for: .meetingNotes, provider: .ollama))
    }
}
