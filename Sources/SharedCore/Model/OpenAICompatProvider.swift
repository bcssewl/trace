import Foundation
import os

public actor OpenAICompatProvider: LLMProvider, EmbeddingProvider {
    public nonisolated var kind: LLMProviderKind { .openAICompat }
    public nonisolated var embeddingKind: EmbeddingProviderKind { .openAICompat }

    private let session: URLSession
    private let keychain: KeychainSecrets

    public init(session: URLSession = .shared, keychain: KeychainSecrets = KeychainSecrets()) {
        self.session = session
        self.keychain = keychain
    }

    public func generate(_ request: LLMRequest, route: LLMRoute) async throws -> LLMResponse {
        let endpoint = try Self.endpoint(route: route, suffix: "chat/completions")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try injectAuthorization(into: &req, route: route)
        req.httpBody = try OllamaProvider.openAIChatBody(request: request, model: route.model, stream: false)

        let (data, response) = try await session.data(for: req)
        try OllamaProvider.validateHTTP(response, provider: "openai-compat")
        return try OllamaProvider.decodeOpenAIResponse(data, provider: "openai-compat", model: route.model)
    }

    public nonisolated func stream(_ request: LLMRequest, route: LLMRoute) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let endpoint = try Self.endpoint(route: route, suffix: "chat/completions")
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    try await injectAuthorization(into: &req, route: route)
                    req.httpBody = try OllamaProvider.openAIChatBody(request: request, model: route.model, stream: true)

                    let (bytes, response) = try await session.bytes(for: req)
                    try OllamaProvider.validateHTTP(response, provider: "openai-compat")
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let payload = String(line.dropFirst("data: ".count))
                            if payload == "[DONE]" { break }
                            if let delta = OllamaProvider.deltaFromOpenAIChunk(payload) {
                                continuation.yield(delta)
                            }
                        }
                    }
                    continuation.yield(LLMDelta(textIncrement: "", isFinal: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func embed(_ texts: [String], route: EmbeddingRoute) async throws -> [[Float]] {
        let endpoint = try Self.endpoint(route: route, suffix: "embeddings")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try injectAuthorization(into: &req, route: route)
        let body: [String: Any] = ["model": route.model, "input": texts]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        try OllamaProvider.validateHTTP(response, provider: "openai-compat")
        let decoded = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: data)
        return decoded.data.map(\.embedding)
    }

    private static func endpoint(route: LLMRoute, suffix: String) throws -> URL {
        guard let base = route.baseURL else {
            throw TraceError.configInvalid(field: "baseURL", reason: "OpenAI-compat route requires baseURL")
        }
        return base.appendingPathComponent(suffix)
    }

    private static func endpoint(route: EmbeddingRoute, suffix: String) throws -> URL {
        guard let base = route.baseURL else {
            throw TraceError.configInvalid(field: "baseURL", reason: "OpenAI-compat embed route requires baseURL")
        }
        return base.appendingPathComponent(suffix)
    }

    private func injectAuthorization(into request: inout URLRequest, route: LLMRoute) throws {
        guard let account = route.keychainAccount else { return }
        guard let token = try keychain.load(account: account) else {
            throw TraceError.configInvalid(field: "apiKey:\(account)", reason: "missing keychain entry")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func injectAuthorization(into request: inout URLRequest, route: EmbeddingRoute) throws {
        guard let account = route.keychainAccount else { return }
        guard let token = try keychain.load(account: account) else {
            throw TraceError.configInvalid(field: "apiKey:\(account)", reason: "missing keychain entry")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

struct OpenAIEmbeddingResponse: Codable {
    struct Item: Codable {
        let embedding: [Float]
        // Optional: only `embedding` is consumed (in input order). Tolerates
        // OpenAI-compatible providers (e.g. OpenRouter) that omit `index`.
        let index: Int?
    }
    let data: [Item]
}
