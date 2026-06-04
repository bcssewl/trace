import Foundation
import SharedCore

/// The user-selectable embedding provider (BAS-17) — a separate axis from the
/// LLM `DictationCleanupProvider` route stages.
///
/// Local Ollama, or a cloud
/// OpenAI-compatible `/v1/embeddings` endpoint: OpenAI, Voyage, or OpenRouter.
/// OpenRouter added an OpenAI-style `/api/v1/embeddings` endpoint in late 2025
/// (models like `openai/text-embedding-3-small`, `qwen/qwen3-embedding-8b`,
/// `google/gemini-embedding-2`) and reuses the same `"openrouter"` Keychain key
/// as the LLM router — so one key serves both routing and embeddings.
public enum EmbeddingProviderChoice: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case ollama
    case openAI
    case voyage
    case openRouter

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .openAI: return "OpenAI"
        case .voyage: return "Voyage"
        case .openRouter: return "OpenRouter"
        }
    }

    /// On-device / no API key required.
    public var isLocal: Bool { self == .ollama }

    /// Placeholder/example hint for the model field (empty for local Ollama,
    /// which uses its own installed-model picker).
    public var modelHint: String {
        switch self {
        case .ollama: return ""
        case .openAI: return "The OpenAI model name — for example text-embedding-3-small or text-embedding-3-large."
        case .voyage: return "The Voyage model name — for example voyage-3-large or voyage-3.5."
        case .openRouter:
            return
                "The OpenRouter model name — for example openai/text-embedding-3-small, qwen/qwen3-embedding-8b, or google/gemini-embedding-2."
        }
    }

    /// Built-in default model per provider (overridable in Settings).
    public var defaultModel: String {
        switch self {
        case .ollama: return "nomic-embed-text"
        case .openAI: return "text-embedding-3-small"
        case .voyage: return "voyage-3-large"
        case .openRouter: return "openai/text-embedding-3-small"
        }
    }

    /// The `ModelRouter` embedding provider kind.
    ///
    /// Every cloud option speaks the
    /// OpenAI-compatible `/v1/embeddings` wire, so they share `OpenAICompatProvider`.
    public var routeProviderKind: EmbeddingProviderKind {
        switch self {
        case .ollama: return .ollama
        case .openAI, .voyage, .openRouter: return .openAICompat
        }
    }

    public var baseURL: URL? {
        switch self {
        case .ollama: return URL(string: "http://localhost:11434")
        case .openAI: return URL(string: "https://api.openai.com/v1")
        case .voyage: return URL(string: "https://api.voyageai.com/v1")
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1")
        }
    }

    /// Keychain account holding the API key (nil for local).
    ///
    /// Voyage reuses the
    /// `"voyage"` account the QA reranker already reads; OpenRouter reuses the
    /// `"openrouter"` account the LLM router already reads — so one key serves both.
    public var keychainAccount: String? {
        switch self {
        case .ollama: return nil
        case .openAI: return "openai"
        case .voyage: return "voyage"
        case .openRouter: return "openrouter"
        }
    }

    /// The router route for this choice + model.
    public func route(model: String) -> EmbeddingRoute {
        EmbeddingRoute(provider: routeProviderKind, model: model, baseURL: baseURL, keychainAccount: keychainAccount)
    }

    /// The shared `EmbeddingConfig` for this choice + model. `provider` is the
    /// raw choice tag — it drives the vector-cache fingerprint (so switching the
    /// model re-namespaces the index) and the Ollama-only availability probe.
    public func config(model: String) -> EmbeddingConfig {
        EmbeddingConfig(provider: rawValue, baseURL: baseURL, model: model, normalization: .unitL2)
    }
}
