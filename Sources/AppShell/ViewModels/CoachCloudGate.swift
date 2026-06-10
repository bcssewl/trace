import Foundation
import SharedCore

extension DictationCleanupProvider {
    /// Whether this provider choice is a keyed cloud provider (OpenRouter /
    /// Anthropic / ChatGPT / MiniMax) — the set the coach is allowed to run on.
    /// Local providers (Apple FM, Ollama) and the deterministic fixer are not.
    public var isCloudCapable: Bool {
        guard let catalog = modelProvider else { return false }
        return ModelProvider.keyedCloudProviders.contains(catalog)
    }
}

/// The coach's cloud-only routing gate (pure + testable).
///
/// The coach needs a
/// capable model, so it REFUSES to run unless `.coachCardContent` is routed to
/// a cloud provider whose credential is actually present. The refusal is loud:
/// the coordinator posts "The coach needs a cloud model. Connect one in
/// Settings → AI models." and the coach does not start — never a silent no-op.
public enum CoachCloudGate {
    /// `true` when `provider` is a cloud provider AND its key/credential is in
    /// `connected` (pass `ModelProvider.routingConnectedSet()`).
    public static func isSatisfied(
        provider: DictationCleanupProvider,
        connected: Set<ModelProvider>
    ) -> Bool {
        guard provider.isCloudCapable, let catalog = provider.modelProvider else { return false }
        return connected.contains(catalog)
    }
}
