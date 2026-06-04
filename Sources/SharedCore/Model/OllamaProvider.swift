import Foundation
import os

public actor OllamaProvider: LLMProvider, EmbeddingProvider {
    public nonisolated var kind: LLMProviderKind { .ollama }
    public nonisolated var embeddingKind: EmbeddingProviderKind { .ollama }

    private let session: URLSession
    private let defaultBaseURL: URL

    public init(session: URLSession = .shared, defaultBaseURL: URL = URL(string: "http://localhost:11434")!) {
        self.session = session
        self.defaultBaseURL = defaultBaseURL
    }

    public func generate(_ request: LLMRequest, route: LLMRoute) async throws -> LLMResponse {
        let base = route.baseURL ?? defaultBaseURL
        let endpoint = base.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.openAIChatBody(request: request, model: route.model, stream: false)

        let (data, response) = try await session.data(for: req)
        try Self.validateHTTP(response, provider: "ollama")
        return try Self.decodeOpenAIResponse(data, provider: "ollama", model: route.model)
    }

    public nonisolated func stream(_ request: LLMRequest, route: LLMRoute) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let base = route.baseURL ?? defaultBaseURL
                    let endpoint = base.appendingPathComponent("v1/chat/completions")
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try Self.openAIChatBody(request: request, model: route.model, stream: true)

                    let (bytes, response) = try await session.bytes(for: req)
                    try Self.validateHTTP(response, provider: "ollama")
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))
                        if payload == "[DONE]" { break }
                        if let delta = Self.deltaFromOpenAIChunk(payload) {
                            continuation.yield(delta)
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
        let base = route.baseURL ?? defaultBaseURL
        let endpoint = base.appendingPathComponent("api/embeddings")
        var results: [[Float]] = []
        for text in texts {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["model": route.model, "prompt": text]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: req)
            try Self.validateHTTP(response, provider: "ollama")
            let decoded = try JSONDecoder().decode(OllamaEmbeddingResponse.self, from: data)
            results.append(decoded.embedding)
        }
        return results
    }

    // MARK: - Shared helpers used by OpenAICompat too.

    static func openAIChatBody(request: LLMRequest, model: String, stream: Bool) throws -> Data {
        let messages = request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
            "temperature": request.temperature,
        ]
        if let max = request.maxTokens { body["max_tokens"] = max }
        if !request.stopSequences.isEmpty { body["stop"] = request.stopSequences }
        if request.responseFormat == .json {
            body["response_format"] = ["type": "json_object"]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func validateHTTP(_ response: URLResponse, provider: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TraceError.networkFailed(provider: provider, statusCode: nil, reason: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TraceError.networkFailed(
                provider: provider, statusCode: http.statusCode, reason: "HTTP \(http.statusCode)")
        }
    }

    static func decodeOpenAIResponse(_ data: Data, provider: String, model: String) throws -> LLMResponse {
        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw TraceError.modelProviderFailed(
                provider: provider,
                underlying: TraceError.configInvalid(field: "response", reason: "no choices")
            )
        }
        let reason: LLMResponse.FinishReason
        switch choice.finish_reason ?? "stop" {
        case "stop": reason = .stop
        case "length": reason = .length
        case "content_filter": reason = .contentFilter
        default: reason = .other
        }
        return LLMResponse(
            text: choice.message.content,
            finishReason: reason,
            usage: LLMUsage(
                promptTokens: decoded.usage?.prompt_tokens ?? 0,
                completionTokens: decoded.usage?.completion_tokens ?? 0
            ),
            provider: provider,
            model: model
        )
    }

    static func deltaFromOpenAIChunk(_ payload: String) -> LLMDelta? {
        guard let data = payload.data(using: .utf8),
            let chunk = try? JSONDecoder().decode(OpenAIChatChunk.self, from: data),
            let delta = chunk.choices.first?.delta.content,
            !delta.isEmpty
        else { return nil }
        return LLMDelta(textIncrement: delta)
    }
}

struct OllamaEmbeddingResponse: Codable {
    let embedding: [Float]
}

struct OpenAIChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let role: String
            let content: String
        }
        let message: Message
        let finish_reason: String?
    }
    struct Usage: Codable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }
    let choices: [Choice]
    let usage: Usage?
}

struct OpenAIChatChunk: Codable {
    struct Choice: Codable {
        struct Delta: Codable {
            let content: String?
        }
        let delta: Delta
    }
    let choices: [Choice]
}
