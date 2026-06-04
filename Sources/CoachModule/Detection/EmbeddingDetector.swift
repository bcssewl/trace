import Accelerate
import Foundation
import SharedCore

public actor EmbeddingDetector {
    public struct Result: Sendable, Hashable {
        public let topHits: [VectorSearch.Hit]
        public let topScore: Float
        public let topicShifted: Bool

        public init(topHits: [VectorSearch.Hit], topScore: Float, topicShifted: Bool) {
            self.topHits = topHits
            self.topScore = topScore
            self.topicShifted = topicShifted
        }
    }

    public static let topicShiftCosineThreshold: Float = 0.55

    private let embedder: EmbeddingClient
    private let vectorSearch: VectorSearch
    private let topK: Int
    private var lastWindowVector: [Float]?

    /// When set, grounded retrieval is restricted to this project (plus global
    /// playbooks). `scopeProjectID` may itself be nil (= unfiled meetings), so a
    /// separate `projectScopeActive` flag distinguishes "scope to nil project" from
    /// "no scoping at all".
    private var scopeProjectID: String?
    private var projectScopeActive = false

    public init(embedder: EmbeddingClient, vectorSearch: VectorSearch, topK: Int = 5) {
        self.embedder = embedder
        self.vectorSearch = vectorSearch
        self.topK = topK
    }

    /// Scope grounded retrieval to `projectID` (the current meeting's project) plus
    /// global playbooks, so the coach never grounds on an unrelated past meeting.
    public func setProjectScope(_ projectID: String?) {
        self.scopeProjectID = projectID
        self.projectScopeActive = true
    }

    public func clearProjectScope() {
        self.scopeProjectID = nil
        self.projectScopeActive = false
    }

    public func evaluate(utterance: String, windowText: String?) async throws -> Result {
        let queryVector = try await embedder.embedForQuery(text: utterance)
        // Playbooks are global reference material (always in scope); everything else
        // must belong to the current meeting's project.
        var filter: (@Sendable (KbChunk) -> Bool)?
        if projectScopeActive {
            let scopeID = scopeProjectID
            filter = { (chunk: KbChunk) -> Bool in
                chunk.sourceKind == .playbook || chunk.projectId == scopeID
            }
        }
        let hits = try await vectorSearch.topK(query: queryVector, k: topK, where: filter)
        let topScore = hits.first?.score ?? 0
        var shifted = false
        if let windowText, !windowText.isEmpty {
            let windowVector = try await embedder.embedForQuery(text: windowText)
            if let prior = lastWindowVector, prior.count == windowVector.count {
                let cosine = Self.cosineNormalized(prior, windowVector)
                if cosine < Self.topicShiftCosineThreshold { shifted = true }
            }
            lastWindowVector = windowVector
        }
        return Result(topHits: hits, topScore: topScore, topicShifted: shifted)
    }

    public func resetTopicWindow() {
        lastWindowVector = nil
    }

    public static func cosineNormalized(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }
}
