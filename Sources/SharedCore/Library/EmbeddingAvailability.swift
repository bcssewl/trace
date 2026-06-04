import Foundation

/// Whether the embedding model the semantic features depend on (Q&A's dense
/// retrieval, meeting indexing, Coach RAG) is actually available.
///
/// Surfaced in the
/// UI so a missing model is a visible, fixable state — never a silent fallback.
public enum EmbeddingAvailability: Sendable, Hashable {
    case ok(model: String)
    case ollamaUnreachable
    case modelMissing(model: String)
    /// Embeddings routed to a non-Ollama provider — availability is governed by
    /// that provider's key/config, checked elsewhere.
    case notApplicable

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    /// True when the user should be prompted to fix something.
    public var needsAttention: Bool {
        switch self {
        case .ok, .notApplicable: return false
        case .ollamaUnreachable, .modelMissing: return true
        }
    }
}

/// Probes whether the configured embedding model is installed and reachable,
/// reusing `OllamaProbe`.
///
/// Network calls go through the injectable `URLSession`
/// (so it's testable without a live Ollama).
public struct EmbeddingAvailabilityChecker: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func check(config: EmbeddingConfig) async -> EmbeddingAvailability {
        guard config.provider.lowercased() == "ollama" else { return .notApplicable }
        let baseURL = config.baseURL ?? URL(string: "http://localhost:11434")!
        let result = await OllamaProbe(session: session, baseURL: baseURL).probe()
        guard result.reachable else { return .ollamaUnreachable }
        return Self.modelPresent(config.model, in: result.models)
            ? .ok(model: config.model)
            : .modelMissing(model: config.model)
    }

    /// Tag-tolerant membership: `nomic-embed-text` matches `nomic-embed-text`,
    /// `nomic-embed-text:latest`, or any `nomic-embed-text:<tag>`.
    public static func modelPresent(_ model: String, in models: [OllamaModel]) -> Bool {
        let wanted = model.lowercased()
        return models.contains { entry in
            let name = entry.name.lowercased()
            return name == wanted || name == "\(wanted):latest" || name.hasPrefix("\(wanted):")
        }
    }
}
