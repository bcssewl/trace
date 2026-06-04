import Foundation

/// `LLMProvider` for Anthropic direct via the Messages API + a BYO API key
/// (`x-api-key`), the sanctioned third-party path (BAS-37). Mirrors
/// `OpenAICompatProvider`'s structure; the request body / response / SSE coding
/// lives in `AnthropicMessagesWire`.
public actor AnthropicMessagesProvider: LLMProvider {
    public nonisolated var kind: LLMProviderKind { .anthropicMessages }

    private let session: URLSession
    private let keychain: KeychainSecrets

    public init(session: URLSession = .shared, keychain: KeychainSecrets = KeychainSecrets()) {
        self.session = session
        self.keychain = keychain
    }

    public func generate(_ request: LLMRequest, route: LLMRoute) async throws -> LLMResponse {
        let body = try AnthropicMessagesWire.requestBody(request, model: route.model, stream: false)
        let req = try authorizedRequest(route: route, body: body)
        let (data, response) = try await session.data(for: req)
        try OllamaProvider.validateHTTP(response, provider: "anthropic")
        return try AnthropicMessagesWire.decodeResponse(data, model: route.model)
    }

    public nonisolated func stream(_ request: LLMRequest, route: LLMRoute) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let body = try AnthropicMessagesWire.requestBody(request, model: route.model, stream: true)
                    let req = try await authorizedRequest(route: route, body: body)
                    let (bytes, response) = try await session.bytes(for: req)
                    try OllamaProvider.validateHTTP(response, provider: "anthropic")
                    // Anthropic SSE carries the event type inside each `data:` JSON,
                    // so parsing the data lines alone is sufficient.
                    for try await line in bytes.lines {
                        guard let payload = StreamingSSE.dataPayload(from: line) else { continue }
                        if let text = AnthropicMessagesWire.textDelta(from: SSEEvent(event: nil, data: payload)) {
                            continuation.yield(LLMDelta(textIncrement: text))
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

    private func authorizedRequest(route: LLMRoute, body: Data) throws -> URLRequest {
        guard let account = route.keychainAccount, let key = try keychain.load(account: account) else {
            throw TraceError.configInvalid(field: "apiKey", reason: "missing Anthropic API key in Keychain")
        }
        return Self.makeRequest(route: route, apiKey: key, body: body)
    }

    /// Builds the `/v1/messages` request with Anthropic's headers.
    ///
    /// Pure + static
    /// so the header set is unit-testable without a network round-trip.
    public static func makeRequest(route: LLMRoute, apiKey: String, body: Data) -> URLRequest {
        let base = route.baseURL ?? URL(string: "https://api.anthropic.com/v1")!
        var req = URLRequest(url: base.appendingPathComponent("messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = body
        return req
    }
}
