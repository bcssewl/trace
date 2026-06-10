import Foundation

/// The catalog of LLM providers the router can target — the single source of
/// truth for every provider's wire kind, endpoint, credential account, and
/// suggested models (the BAS-36 core).
///
/// One `route(model:)` builder turns a
/// catalog entry into an `LLMRoute`, so the per-stage mapping
/// (`AppRuntimeCoordinator.providerRoute`), the per-project mapping
/// (`ProjectLLMProvider.route`), and `ModelRouter.defaultLLMRoutes` all read
/// endpoints + accounts from *here* instead of hardcoding them in four places.
///
/// Raw values match the UI picker enum `DictationCleanupProvider` 1:1, so the
/// two bridge by raw value while the picker's `.deterministic` (no-LLM) case
/// stays UI-only. Adding a provider = one case here (+ its metadata) and one
/// bridging case on `DictationCleanupProvider`.
public enum ModelProvider: String, Sendable, Hashable, CaseIterable, Identifiable {
    case appleFM
    case ollama
    case openRouter
    case anthropic
    case minimax
    case chatgpt

    public var id: String { rawValue }

    /// How the user supplies credentials. `.builtin` (on-device Apple FM) and
    /// `.localURL` (Ollama) need none; `.apiKey` stores a key in the Keychain;
    /// `.oauth` signs in via the system browser.
    public enum Connection: Sendable, Hashable {
        case builtin
        case localURL
        case apiKey
        case oauth
    }

    public var connection: Connection {
        switch self {
        case .appleFM: return .builtin
        case .ollama: return .localURL
        case .openRouter, .anthropic, .minimax: return .apiKey
        case .chatgpt: return .oauth
        }
    }

    public var displayName: String {
        switch self {
        case .appleFM: return "Apple Foundation Models"
        case .ollama: return "Ollama (local)"
        case .openRouter: return "OpenRouter (BYOK)"
        case .anthropic: return "Anthropic"
        case .minimax: return "MiniMax"
        case .chatgpt: return "ChatGPT (Codex)"
        }
    }

    /// `true` for OAuth-subscription providers (sign-in, no key field).
    public var usesOAuth: Bool { connection == .oauth }

    /// The `LLMProviderKind` (wire adapter) a route to this provider uses.
    ///
    /// OpenRouter and MiniMax are both OpenAI-compatible; they differ only by
    /// base URL + account, which is exactly why this catalog layer exists.
    public var routeProviderKind: LLMProviderKind {
        switch self {
        case .appleFM: return .appleFM
        case .ollama: return .ollama
        case .openRouter, .minimax: return .openAICompat
        case .anthropic: return .anthropicMessages
        case .chatgpt: return .codexSubscription
        }
    }

    /// Endpoint base URL (`nil` for on-device Apple FM and for ChatGPT, which
    /// uses the fixed Codex backend baked into its adapter).
    public var baseURL: URL? {
        switch self {
        case .appleFM, .chatgpt: return nil
        case .ollama: return URL(string: "http://localhost:11434")
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1")
        case .anthropic: return URL(string: "https://api.anthropic.com/v1")
        case .minimax: return URL(string: "https://api.minimax.io/v1")
        }
    }

    /// Keychain account for the credential, or `nil` when none is needed
    /// (on-device / local) or the adapter manages its own (ChatGPT OAuth).
    public var keychainAccount: String? {
        switch self {
        case .appleFM, .ollama, .chatgpt: return nil
        case .openRouter: return "openrouter"
        case .anthropic: return "anthropic"
        case .minimax: return "minimax"
        }
    }

    /// Suggested model ids (user-overridable; vendors version these often).
    ///
    /// The
    /// first is the default when the caller hasn't chosen one.
    public var defaultModels: [String] {
        switch self {
        case .appleFM: return ["apple-fm-default"]
        case .ollama: return ["llama3.2"]
        case .openRouter: return ["google/gemini-3.1-flash-lite", "google/gemini-3.5-flash"]
        case .anthropic: return ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]
        case .minimax: return ["MiniMax-M2.7", "MiniMax-M2.5", "MiniMax-M2"]
        case .chatgpt: return ["gpt-5.1", "gpt-5.1-codex"]
        }
    }

    /// The model used when the caller passes an empty string.
    public var defaultModel: String { defaultModels.first ?? "" }

    /// THE single route builder — every per-stage / per-project / default route
    /// resolves through here, so endpoint + account live only in this file.
    public func route(model: String) -> LLMRoute {
        LLMRoute(
            provider: routeProviderKind,
            model: model.isEmpty ? defaultModel : model,
            baseURL: baseURL,
            keychainAccount: keychainAccount
        )
    }

    /// The BAS-37 "Connect providers" cards (Anthropic key / MiniMax key / ChatGPT
    /// OAuth) — surfaced in the routing pickers only once connected.
    ///
    /// Together with
    /// OpenRouter they form `keyedCloudProviders`; only Apple FM / Ollama are
    /// offered unconditionally by `LLMRouteStage.offeredProviders`.
    public static let connectCards: [ModelProvider] = [.anthropic, .minimax, .chatgpt]

    /// Whether a usable credential is present for this provider right now — a
    /// synchronous Keychain check (BAS-60).
    ///
    /// Local / on-device providers are
    /// always "connected"; key / OAuth providers check the stored credential.
    public func isConnected(keychain: KeychainSecrets = KeychainSecrets()) -> Bool {
        switch connection {
        case .builtin, .localURL:
            return true
        case .apiKey:
            guard let account = keychainAccount else { return true }
            return keychain.hasValue(account: account)
        case .oauth:
            return keychain.hasValue(account: CodexAuth.keychainAccount)
        }
    }

    /// Every cloud provider the per-task routing pickers gate behind a credential:
    /// OpenRouter (BYOK key) plus the connect-card providers (Anthropic / ChatGPT /
    /// MiniMax).
    ///
    /// Only the always-on local providers (Apple FM / Ollama) and the
    /// no-LLM deterministic option are offered unconditionally — so you can never
    /// pick a cloud provider you have no key for.
    public static let keyedCloudProviders: [ModelProvider] = [.openRouter] + connectCards

    /// The keyed cloud providers with a usable credential present right now — the
    /// gating set the per-task pickers union with their always-on local list, so a
    /// provider without a key (OpenRouter included) is never offered.
    public static func routingConnectedSet(keychain: KeychainSecrets = KeychainSecrets()) -> Set<ModelProvider> {
        Set(keyedCloudProviders.filter { $0.isConnected(keychain: keychain) })
    }

    /// Marketing blurb for the connect cards (only the BYOK / OAuth ones surface it).
    public var connectBlurb: String {
        switch self {
        case .anthropic: return "Claude via the Anthropic API. Paste an API key (x-api-key)."
        case .minimax: return "MiniMax coding-plan via the OpenAI-compatible API. Paste an API key."
        case .chatgpt: return "Use your ChatGPT subscription via OAuth (system browser sign-in)."
        case .appleFM: return "On-device Apple Foundation Models. No setup."
        case .ollama: return "Local models via Ollama at localhost:11434."
        case .openRouter: return "Cloud models via OpenRouter. Paste an API key (BYOK)."
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .minimax, .openRouter: return "API key"
        case .appleFM, .ollama, .chatgpt: return ""
        }
    }
}
