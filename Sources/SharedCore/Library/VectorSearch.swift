import Accelerate
import Foundation

public actor VectorSearch {
    public struct Hit: Sendable, Hashable {
        public let chunk: KbChunk
        public let score: Float
        public init(chunk: KbChunk, score: Float) {
            self.chunk = chunk
            self.score = score
        }
    }

    private let cache: KbCache
    private let config: EmbeddingConfig
    private var loaded: [(chunk: KbChunk, embedding: KbEmbedding)] = []
    private var loadedFingerprint: String?

    public init(cache: KbCache, config: EmbeddingConfig) {
        self.cache = cache
        self.config = config
    }

    public func refresh() async throws {
        loaded = try await cache.loadValid(config: config)
        loadedFingerprint = config.fingerprint
    }

    public func topK(
        query: [Float],
        k: Int,
        sourceFilePrefix: String? = nil,
        where filter: (@Sendable (KbChunk) -> Bool)? = nil
    ) async throws -> [Hit] {
        guard k > 0, !query.isEmpty else { return [] }
        if loadedFingerprint != config.fingerprint {
            try await refresh()
        }
        let normalizedQuery: [Float]
        switch config.normalization {
        case .unitL2: normalizedQuery = EmbeddingClient.unitL2(query)
        case .none: normalizedQuery = query
        }
        var scored: [Hit] = []
        scored.reserveCapacity(loaded.count)
        for entry in loaded {
            if let prefix = sourceFilePrefix, !entry.chunk.sourceFile.hasPrefix(prefix) { continue }
            if let filter, !filter(entry.chunk) { continue }
            guard entry.embedding.vector.count == normalizedQuery.count else { continue }
            var dot: Float = 0
            vDSP_dotpr(
                entry.embedding.vector, 1, normalizedQuery, 1, &dot,
                vDSP_Length(normalizedQuery.count)
            )
            scored.append(Hit(chunk: entry.chunk, score: dot))
        }
        scored.sort { $0.score > $1.score }
        if scored.count > k {
            scored.removeLast(scored.count - k)
        }
        return scored
    }

    public func indexedChunkCount() -> Int { loaded.count }
}
