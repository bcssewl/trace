import Accelerate
import Foundation

public actor EmbeddingClient {
    private let router: ModelRouter
    public let config: EmbeddingConfig
    private let task: EmbeddingTaskClass

    public init(router: ModelRouter, config: EmbeddingConfig, task: EmbeddingTaskClass = .embeddingsIndex) {
        self.router = router
        self.config = config
        self.task = task
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let raw = try await router.embed(texts: texts, task: task)
        switch config.normalization {
        case .unitL2: return raw.map(Self.unitL2)
        case .none: return raw
        }
    }

    public func embedOne(_ text: String) async throws -> [Float] {
        let batch = try await embed([text])
        return batch.first ?? []
    }

    public func embedForIndex(texts: [String]) async throws -> [[Float]] {
        try await embed(texts)
    }

    public func embedForQuery(text: String) async throws -> [Float] {
        try await embedOne(text)
    }

    public static func unitL2(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return vector }
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let magnitude = sumOfSquares.squareRoot()
        guard magnitude > .ulpOfOne else { return vector }
        var inv: Float = 1 / magnitude
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &inv, &result, 1, vDSP_Length(vector.count))
        return result
    }
}
