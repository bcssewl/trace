import Foundation

/// One LLM stage's persisted provider + per-provider model overrides — the
/// generalized replacement for the hand-rolled `<stage>Provider` + `<stage>Models`
/// pairs (BAS-49).
///
/// Restores from / persists to the stage's exact legacy
/// UserDefaults keys and applies the stage's `.deterministic` coercion on
/// restore. A plain `Sendable` value type; `AppStateModel` (`@MainActor`) owns
/// the instances and is the only mutator.
struct RoutedStagePreference: Sendable {
    let stage: LLMRouteStage
    var provider: DictationCleanupProvider
    var models: [String: String]

    /// Restore from UserDefaults, applying the stage default + `.deterministic`
    /// coercion.
    ///
    /// Read-only — mirrors the legacy init (no writes during init).
    init(stage: LLMRouteStage, defaults: UserDefaults = .standard) {
        self.stage = stage
        let restored =
            defaults.string(forKey: stage.providerKey)
            .flatMap(DictationCleanupProvider.init(rawValue:)) ?? stage.defaultProvider
        if restored == .deterministic, let coerced = stage.deterministicCoercion {
            self.provider = coerced
        } else if stage == .coachCardContent, !restored.isCloudCapable {
            // The coach is cloud-only (the listener redesign). A preference
            // persisted by an older build may still say Apple FM / Ollama —
            // coerce to the cloud default so an upgrade lands on a runnable
            // route instead of a guaranteed refusal.
            self.provider = stage.defaultProvider
        } else {
            self.provider = restored
        }
        if let data = defaults.data(forKey: stage.modelsKey),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            self.models = decoded
        } else {
            self.models = [:]
        }
    }

    /// Persist provider + models to the stage's legacy keys.
    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: stage.providerKey)
        if let data = try? JSONEncoder().encode(models) {
            defaults.set(data, forKey: stage.modelsKey)
        }
    }

    /// The user's explicit, non-blank model override for `provider`, or `nil`
    /// when unset/blank (caller falls back to the stage default model).
    func modelOverride(for provider: DictationCleanupProvider) -> String? {
        guard let raw = models[provider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw
    }
}
