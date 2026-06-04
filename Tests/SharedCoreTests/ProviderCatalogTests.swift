import XCTest

@testable import SharedCore

/// BAS-37 / BAS-36 — guards the `ModelProvider` catalog (keychain accounts, route
/// kinds, OAuth flag, endpoints) against typos, since the connect UI, the per-stage
/// + per-project route mappings, and `ModelRouter`'s default routes all key off it.
final class ProviderCatalogTests: XCTestCase {
    func testKeychainAccountsAndOAuthFlag() {
        XCTAssertEqual(ModelProvider.anthropic.keychainAccount, "anthropic")
        XCTAssertEqual(ModelProvider.minimax.keychainAccount, "minimax")
        XCTAssertEqual(ModelProvider.openRouter.keychainAccount, "openrouter")
        XCTAssertNil(ModelProvider.chatgpt.keychainAccount, "ChatGPT is OAuth — no key field")
        XCTAssertNil(ModelProvider.appleFM.keychainAccount)
        XCTAssertNil(ModelProvider.ollama.keychainAccount)
        XCTAssertTrue(ModelProvider.chatgpt.usesOAuth)
        XCTAssertFalse(ModelProvider.anthropic.usesOAuth)
        XCTAssertFalse(ModelProvider.minimax.usesOAuth)
    }

    func testRouteProviderKinds() {
        XCTAssertEqual(ModelProvider.appleFM.routeProviderKind, .appleFM)
        XCTAssertEqual(ModelProvider.ollama.routeProviderKind, .ollama)
        XCTAssertEqual(ModelProvider.openRouter.routeProviderKind, .openAICompat)
        XCTAssertEqual(ModelProvider.minimax.routeProviderKind, .openAICompat)
        XCTAssertEqual(ModelProvider.anthropic.routeProviderKind, .anthropicMessages)
        XCTAssertEqual(ModelProvider.chatgpt.routeProviderKind, .codexSubscription)
    }

    func testCloudKeyProvidersHaveBaseURLAndModels() {
        for provider in [ModelProvider.anthropic, .minimax, .openRouter] {
            XCTAssertNotNil(provider.baseURL)
            XCTAssertFalse(provider.defaultModels.isEmpty)
        }
        XCTAssertNil(ModelProvider.chatgpt.baseURL, "ChatGPT uses the fixed Codex backend")
        XCTAssertNil(ModelProvider.appleFM.baseURL, "Apple FM is on-device")
    }

    /// The single `route(model:)` builder is what every routing site now delegates
    /// to — pin its output so per-stage / per-project / default routes stay aligned.
    func testRouteBuilderUsesCatalogMetadata() {
        let openRouter = ModelProvider.openRouter.route(model: "openai/gpt-5")
        XCTAssertEqual(openRouter.provider, .openAICompat)
        XCTAssertEqual(openRouter.model, "openai/gpt-5")
        XCTAssertEqual(openRouter.baseURL, URL(string: "https://openrouter.ai/api/v1"))
        XCTAssertEqual(openRouter.keychainAccount, "openrouter")

        // Empty model falls back to the catalog default.
        XCTAssertEqual(ModelProvider.ollama.route(model: "").model, "llama3.2")
        XCTAssertEqual(ModelProvider.appleFM.route(model: "").model, "apple-fm-default")

        // MiniMax shares the OpenAI-compatible wire but its own endpoint + account.
        let minimax = ModelProvider.minimax.route(model: "MiniMax-M2.7")
        XCTAssertEqual(minimax.provider, .openAICompat)
        XCTAssertEqual(minimax.baseURL, URL(string: "https://api.minimax.io/v1"))
        XCTAssertEqual(minimax.keychainAccount, "minimax")

        // ChatGPT carries no URL/account — its adapter reads its own OAuth store.
        let chatgpt = ModelProvider.chatgpt.route(model: "gpt-5.1")
        XCTAssertEqual(chatgpt.provider, .codexSubscription)
        XCTAssertNil(chatgpt.baseURL)
        XCTAssertNil(chatgpt.keychainAccount)
    }

    func testConnectCardsAreTheGatedProviders() {
        XCTAssertEqual(ModelProvider.connectCards, [.anthropic, .minimax, .chatgpt])
        // Local/on-device providers are always "connected" (no credential needed).
        XCTAssertTrue(ModelProvider.appleFM.isConnected())
        XCTAssertTrue(ModelProvider.ollama.isConnected())
    }
}
