import Foundation
import SharedCore

/// Single source of truth for the default model-provider set the app registers:
/// Apple Foundation Models (LLM) + Ollama (LLM + embeddings) + an
/// OpenAI-compatible provider (LLM + embeddings, e.g. OpenAI / OpenRouter).
enum ModelRouterFactory {
    static func makeDefaultRouter() async -> ModelRouter {
        let router = ModelRouter()
        let appleFM: any LLMProvider = AppleFMProvider()
        let ollama = OllamaProvider()
        let openai = OpenAICompatProvider()
        await router.register(provider: appleFM)
        await router.register(provider: ollama as any LLMProvider)
        await router.register(provider: ollama as any EmbeddingProvider)
        await router.register(provider: openai as any LLMProvider)
        await router.register(provider: openai as any EmbeddingProvider)
        // BAS-37: Anthropic-direct + ChatGPT/Codex OAuth — registered so routes
        // pointing at `.anthropicMessages` / `.codexSubscription` resolve; each
        // needs a credential in Keychain or it throws -> deterministic fallback.
        await router.register(provider: AnthropicMessagesProvider())
        await router.register(provider: CodexSubscriptionProvider())
        return router
    }
}
