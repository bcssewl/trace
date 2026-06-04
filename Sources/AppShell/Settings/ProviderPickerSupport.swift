import SharedCore
import SwiftUI

/// Shared provider-picker helpers (BAS refactor): the single home for the
/// `label` / `offered` / `detail` logic and the brand-logo maps that the LLM
/// Router, Coach, and Meetings settings used to each copy verbatim.
///
/// It's a small value type seeded with the live availability + connected-provider
/// snapshot a settings view already holds in `@State`, so a view builds one
/// `ProviderPickerSupport` per render and asks it for labels/details/logos. This
/// keeps the brand mapping and the "· NO KEY"/"· OFFLINE" degradation rules in
/// one place instead of three.
@MainActor
struct ProviderPickerSupport {
    let availability: DictationAvailability
    let connectedProviders: Set<ModelProvider>

    // MARK: Provider availability label (Picker / list-row title suffix)

    /// The provider's display name, degraded with a status suffix when the
    /// provider isn't actually usable right now (no key / offline / disconnected).
    func label(for provider: DictationCleanupProvider) -> String {
        switch provider {
        case .deterministic: return provider.displayName
        case .appleFM:
            return availability.appleFM ? provider.displayName : "\(provider.displayName) · not available"
        case .ollama:
            return availability.ollamaReachable ? provider.displayName : "\(provider.displayName) · not running"
        case .openRouter:
            return availability.openRouterKeySet ? provider.displayName : "\(provider.displayName) · needs a key"
        case .anthropic, .chatgpt, .minimax:
            let connected = provider.modelProvider.map { connectedProviders.contains($0) } ?? false
            return connected ? provider.displayName : "\(provider.displayName) · not connected"
        }
    }

    /// Whether the provider is usable right now — drives whether a degraded
    /// suffix is shown and (for cloud-ASR-style gating) whether it's selectable.
    func isAvailable(_ provider: DictationCleanupProvider) -> Bool {
        switch provider {
        case .deterministic: return true
        case .appleFM: return availability.appleFM
        case .ollama: return availability.ollamaReachable
        case .openRouter: return availability.openRouterKeySet
        case .anthropic, .chatgpt, .minimax:
            return provider.modelProvider.map { connectedProviders.contains($0) } ?? false
        }
    }

    /// Compact "local / cloud · state" detail for the `BrutalistSelectRow` trailing
    /// text (the list idiom Meetings already uses).
    func detail(for provider: DictationCleanupProvider) -> String {
        switch provider {
        case .deterministic: return "Built in · no AI"
        case .appleFM: return availability.appleFM ? "On your Mac · free" : "On your Mac · not available"
        case .ollama: return availability.ollamaReachable ? "On your Mac" : "On your Mac · not running"
        case .openRouter: return availability.openRouterKeySet ? "Cloud · connected" : "Cloud · needs a key"
        case .anthropic, .chatgpt, .minimax:
            let connected = provider.modelProvider.map { connectedProviders.contains($0) } ?? false
            return connected ? "Cloud · connected" : "Cloud · not connected"
        }
    }

    /// Status chip for a provider-picker group header.
    func groupTag(for provider: DictationCleanupProvider) -> String {
        switch provider {
        case .deterministic:
            // The no-LLM fixer is always usable (dictation cleanup only); other
            // stages never select it.
            return "Always available"
        case .appleFM:
            return availability.appleFM ? "Apple Intelligence on" : "Apple Intelligence off"
        case .ollama:
            return availability.ollamaReachable ? "Ollama connected" : "Ollama offline"
        case .openRouter:
            return availability.openRouterKeySet ? "OpenRouter connected" : "OpenRouter needs a key"
        case .anthropic, .chatgpt, .minimax:
            let connected = provider.modelProvider.map { connectedProviders.contains($0) } ?? false
            return connected ? "\(provider.displayName) connected" : "\(provider.displayName) not connected"
        }
    }

    /// The providers a stage's picker offers: always-on local + currently-connected
    /// cloud providers, plus the current selection even if it has since
    /// disconnected — so a list/picker never renders a blank selection (BAS-60).
    func offered(for stage: LLMRouteStage, current: DictationCleanupProvider) -> [DictationCleanupProvider] {
        var list = stage.everydayProviders(connected: connectedProviders)
        if !list.contains(current) { list.append(current) }
        return list
    }
}

// MARK: Brand-logo mappings (dropdown rows only)

extension DictationCleanupProvider {
    /// The brand logo for this provider in a selection dropdown.
    ///
    /// Nil for the
    /// non-brand options (deterministic fixer, MiniMax has no bundled mark).
    var brandLogo: BrandLogo? {
        switch self {
        case .appleFM: return .apple
        case .ollama: return .ollama
        case .openRouter: return .openRouter
        case .anthropic: return .anthropic
        case .chatgpt: return .openAI
        case .minimax, .deterministic: return nil
        }
    }
}

extension EmbeddingProviderChoice {
    /// The brand logo for this embedding provider in a selection dropdown.
    var brandLogo: BrandLogo? {
        switch self {
        case .ollama: return .ollama
        case .openAI: return .openAI
        case .voyage: return .voyage
        case .openRouter: return .openRouter
        }
    }
}

extension CloudASRProvider {
    /// The brand logo for this cloud ASR provider in a selection dropdown.
    var brandLogo: BrandLogo {
        switch self {
        case .openai: return .openAI
        case .groq: return .groq
        case .deepgram: return .deepgram
        case .assemblyAI: return .assemblyAI
        case .revAI: return .rev
        case .speechmatics: return .speechmatics
        case .soniox: return .soniox
        case .elevenlabs: return .elevenLabs
        case .fireworks: return .fireworks
        case .volcengine: return .volcengine
        }
    }
}
