import Foundation

public actor Reranker {

    public struct Candidate: Sendable, Hashable {
        public let chunkId: String
        public let text: String
        public init(chunkId: String, text: String) {
            self.chunkId = chunkId
            self.text = text
        }
    }

    public struct Ranked: Sendable, Hashable {
        public let chunkId: String
        public let score: Float
        public init(chunkId: String, score: Float) {
            self.chunkId = chunkId
            self.score = score
        }
    }

    public protocol Backend: Sendable {
        func rerank(query: String, candidates: [Candidate]) async throws -> [Ranked]
    }

    private let backend: any Backend
    private let topK: Int

    public init(backend: any Backend, topK: Int = 8) {
        self.backend = backend
        self.topK = topK
    }

    public func rerank(query: String, candidates: [Candidate]) async throws -> [Ranked] {
        guard !candidates.isEmpty else { return [] }
        let scored = try await backend.rerank(query: query, candidates: candidates)
        let sorted = scored.sorted { $0.score > $1.score }
        if sorted.count > topK {
            return Array(sorted.prefix(topK))
        }
        return sorted
    }
}

public struct VoyageRerankerBackend: Reranker.Backend {
    public let session: URLSession
    public let endpoint: URL
    public let model: String
    public let keychainAccount: String
    public let keychain: KeychainSecrets

    public init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.voyageai.com/v1/rerank")!,
        model: String = "voyage-rerank-2.5-lite",
        keychainAccount: String = "voyage",
        keychain: KeychainSecrets = KeychainSecrets()
    ) {
        self.session = session
        self.endpoint = endpoint
        self.model = model
        self.keychainAccount = keychainAccount
        self.keychain = keychain
    }

    public func rerank(
        query: String, candidates: [Reranker.Candidate]
    ) async throws -> [Reranker.Ranked] {
        guard let token = try keychain.load(account: keychainAccount), !token.isEmpty else {
            throw TraceError.configInvalid(
                field: "voyage.apiKey",
                reason: "missing voyage API key in keychain account \(keychainAccount)"
            )
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": model,
            "query": query,
            "documents": candidates.map(\.text),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw TraceError.networkFailed(
                provider: "voyage",
                statusCode: http.statusCode,
                reason: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try Self.parseResponse(data: data, candidates: candidates)
    }

    static func parseResponse(
        data: Data, candidates: [Reranker.Candidate]
    ) throws -> [Reranker.Ranked] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["data"] as? [[String: Any]] else {
            throw TraceError.networkFailed(provider: "voyage", statusCode: nil, reason: "missing data array")
        }
        var ranked: [Reranker.Ranked] = []
        for entry in results {
            guard let index = entry["index"] as? Int,
                let score = entry["relevance_score"] as? Double,
                index >= 0, index < candidates.count
            else { continue }
            ranked.append(Reranker.Ranked(chunkId: candidates[index].chunkId, score: Float(score)))
        }
        return ranked
    }
}
