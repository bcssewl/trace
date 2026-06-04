import SharedCore
import XCTest

@testable import AppShell

/// BAS-17 — the embedding provider + model is user-selectable (a separate axis
/// from the LLM `DictationCleanupProvider` stages).
///
/// Local Ollama or a cloud
/// OpenAI-compatible `/v1/embeddings` provider (OpenAI / Voyage / OpenRouter).
/// These tests pin the provider→route/config mapping and the persisted preference.
@MainActor
final class EmbeddingConfigTests: XCTestCase {
    // Must match `AppStateModel.embeddingProviderKey` / `embeddingModelsKey`, or
    // setUp/tearDown clear the wrong key and stale state leaks between tests.
    private let providerKey = "app.trace.embedding.provider"
    private let modelsKey = "app.trace.embedding.models"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: providerKey)
        UserDefaults.standard.removeObject(forKey: modelsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: providerKey)
        UserDefaults.standard.removeObject(forKey: modelsKey)
        super.tearDown()
    }

    // MARK: provider choices

    func testEmbeddingChoicesIncludeOpenRouter() {
        // Local Ollama + the OpenAI-compatible cloud endpoints. OpenRouter added an
        // OpenAI-style /api/v1/embeddings endpoint in late 2025, so it's now a valid
        // choice (reusing the same "openrouter" key as the LLM router).
        XCTAssertEqual(EmbeddingProviderChoice.allCases, [.ollama, .openAI, .voyage, .openRouter])
    }

    func testOllamaChoiceMapsToLocalRoute() {
        let choice = EmbeddingProviderChoice.ollama
        XCTAssertTrue(choice.isLocal)
        let route = choice.route(model: "nomic-embed-text")
        XCTAssertEqual(route.provider, .ollama)
        XCTAssertEqual(route.model, "nomic-embed-text")
        XCTAssertEqual(route.baseURL, URL(string: "http://localhost:11434"))
        XCTAssertNil(route.keychainAccount)
        XCTAssertEqual(choice.defaultModel, "nomic-embed-text")
    }

    func testOpenAIChoiceMapsToOpenAICompatCloudRoute() {
        let choice = EmbeddingProviderChoice.openAI
        XCTAssertFalse(choice.isLocal)
        let route = choice.route(model: choice.defaultModel)
        XCTAssertEqual(route.provider, .openAICompat)
        XCTAssertEqual(route.baseURL, URL(string: "https://api.openai.com/v1"))
        XCTAssertEqual(route.keychainAccount, "openai")
        XCTAssertEqual(choice.defaultModel, "text-embedding-3-small")
    }

    func testVoyageChoiceMapsToOpenAICompatCloudRouteWithVoyageAccount() {
        let choice = EmbeddingProviderChoice.voyage
        XCTAssertFalse(choice.isLocal)
        let route = choice.route(model: choice.defaultModel)
        XCTAssertEqual(route.provider, .openAICompat)
        XCTAssertEqual(route.baseURL, URL(string: "https://api.voyageai.com/v1"))
        // Reuses the same Keychain account the QA reranker reads (coordinator).
        XCTAssertEqual(route.keychainAccount, "voyage")
    }

    func testOpenRouterChoiceMapsToOpenAICompatCloudRouteWithOpenRouterAccount() {
        let choice = EmbeddingProviderChoice.openRouter
        XCTAssertFalse(choice.isLocal)
        let route = choice.route(model: choice.defaultModel)
        XCTAssertEqual(route.provider, .openAICompat)
        XCTAssertEqual(route.baseURL, URL(string: "https://openrouter.ai/api/v1"))
        // Reuses the same Keychain account the LLM router reads, so one key serves both.
        XCTAssertEqual(route.keychainAccount, "openrouter")
        XCTAssertEqual(choice.defaultModel, "openai/text-embedding-3-small")
    }

    func testConfigProviderTagDrivesOllamaAvailabilityProbe() {
        // EmbeddingAvailabilityChecker only probes when provider == "ollama".
        XCTAssertEqual(EmbeddingProviderChoice.ollama.config(model: "nomic-embed-text").provider.lowercased(), "ollama")
        XCTAssertNotEqual(EmbeddingProviderChoice.openAI.config(model: "x").provider.lowercased(), "ollama")
        XCTAssertNotEqual(EmbeddingProviderChoice.voyage.config(model: "x").provider.lowercased(), "ollama")
    }

    // MARK: AppStateModel preference

    func testDefaultsToLocalOllama() {
        let state = AppStateModel()
        XCTAssertEqual(state.embeddingProvider, .ollama, "all-local default")
        XCTAssertEqual(state.embeddingModel(for: .ollama), "nomic-embed-text")
    }

    func testPersistsProviderAndModel() {
        let state = AppStateModel()
        state.embeddingProvider = .openAI
        XCTAssertEqual(UserDefaults.standard.string(forKey: providerKey), "openAI")
        state.setEmbeddingModel("text-embedding-3-large", for: .openAI)
        XCTAssertEqual(state.embeddingModel(for: .openAI), "text-embedding-3-large")
        // Restores.
        let restored = AppStateModel()
        XCTAssertEqual(restored.embeddingProvider, .openAI)
        XCTAssertEqual(restored.embeddingModel(for: .openAI), "text-embedding-3-large")
    }

    func testBlankModelClearsToDefault() {
        let state = AppStateModel()
        state.setEmbeddingModel("custom-model", for: .ollama)
        XCTAssertEqual(state.embeddingModel(for: .ollama), "custom-model")
        state.setEmbeddingModel("", for: .ollama)
        XCTAssertEqual(state.embeddingModel(for: .ollama), "nomic-embed-text")
    }

    func testRouteAndConfigReflectCurrentChoice() {
        let state = AppStateModel()
        state.embeddingProvider = .voyage
        XCTAssertEqual(state.embeddingRoute().provider, .openAICompat)
        XCTAssertEqual(state.embeddingRoute().baseURL, URL(string: "https://api.voyageai.com/v1"))
        XCTAssertEqual(state.embeddingConfig().model, state.embeddingModel(for: .voyage))
    }

    func testChangingModelChangesConfigFingerprint() {
        // A model switch must re-namespace the vector cache (different dimensions).
        let state = AppStateModel()
        let before = state.embeddingConfig().fingerprint
        state.embeddingProvider = .openAI
        XCTAssertNotEqual(state.embeddingConfig().fingerprint, before)
    }

    func testChangingProviderPostsEmbeddingNotification() {
        let state = AppStateModel()
        let exp = expectation(forNotification: .traceEmbeddingConfigChanged, object: nil)
        state.embeddingProvider = .openAI
        wait(for: [exp], timeout: 1.0)
    }
}
