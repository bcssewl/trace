import Foundation

/// Refreshes a Codex OAuth credential.
///
/// A protocol so the provider can be tested
/// with a stub and the live impl can be swapped (BAS-37).
public protocol CodexTokenRefreshing: Sendable {
    func refresh(_ credential: OAuthCredential) async throws -> OAuthCredential
}

/// Live refresher — `POST https://auth.openai.com/oauth/token` (JSON).
public struct CodexTokenRefresher: CodexTokenRefreshing {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func refresh(_ credential: OAuthCredential) async throws -> OAuthCredential {
        var req = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = CodexAuth.refreshBody(refreshToken: credential.refreshToken)
        let (data, response) = try await session.data(for: req)
        try OllamaProvider.validateHTTP(response, provider: "codex-oauth")
        let token = try JSONDecoder().decode(CodexTokenResponse.self, from: data)
        return OAuthCredential(
            accessToken: token.access_token,
            refreshToken: token.refresh_token ?? credential.refreshToken,
            idToken: token.id_token ?? credential.idToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600)),
            accountId: credential.accountId
        )
    }
}

/// `LLMProvider` for the ChatGPT/Codex OAuth subscription → the ChatGPT-backend
/// Responses API (BAS-37). Resolves + proactively refreshes the stored OAuth
/// credential, then streams `codex/responses`. `generate` collects the stream
/// (the Responses API is stream-only).
public actor CodexSubscriptionProvider: LLMProvider {
    public nonisolated var kind: LLMProviderKind { .codexSubscription }

    private let session: URLSession
    private let tokenStore: OAuthTokenStore
    private let refresher: CodexTokenRefreshing

    public init(
        session: URLSession = .shared,
        tokenStore: OAuthTokenStore? = nil,
        refresher: CodexTokenRefreshing? = nil
    ) {
        self.session = session
        self.tokenStore = tokenStore ?? OAuthTokenStore(account: CodexAuth.keychainAccount)
        self.refresher = refresher ?? CodexTokenRefresher(session: session)
    }

    public func generate(_ request: LLMRequest, route: LLMRoute) async throws -> LLMResponse {
        var text = ""
        for try await delta in stream(request, route: route) {
            text += delta.textIncrement
        }
        return LLMResponse(text: text, finishReason: .stop, usage: .zero, provider: "codex", model: route.model)
    }

    public nonisolated func stream(_ request: LLMRequest, route: LLMRoute) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let credential = try await validCredential()
                    guard let accountId = credential.accountId else {
                        throw TraceError.configInvalid(
                            field: "chatgpt-account-id", reason: "missing account id; sign in again")
                    }
                    let body = try ResponsesAPI.requestBody(request, model: route.model)
                    let req = Self.makeRequest(accessToken: credential.accessToken, accountId: accountId, body: body)
                    let (bytes, response) = try await session.bytes(for: req)
                    try OllamaProvider.validateHTTP(response, provider: "codex")
                    for try await line in bytes.lines {
                        guard let payload = StreamingSSE.dataPayload(from: line) else { continue }
                        if payload == "[DONE]" { break }
                        let event = SSEEvent(event: nil, data: payload)
                        if let message = ResponsesAPI.error(from: event) {
                            throw TraceError.modelProviderFailed(
                                provider: "codex",
                                underlying: TraceError.configInvalid(field: "response", reason: message)
                            )
                        }
                        if let text = ResponsesAPI.textDelta(from: event) {
                            continuation.yield(LLMDelta(textIncrement: text))
                        }
                        if ResponsesAPI.isCompleted(event) { break }
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

    /// The stored credential, refreshed if it's within the expiry skew.
    ///
    /// Throws a
    /// "sign in" error when nothing is stored.
    private func validCredential() async throws -> OAuthCredential {
        guard let credential = try await tokenStore.current() else {
            throw TraceError.configInvalid(field: "oauth", reason: "Sign in with ChatGPT first")
        }
        guard OAuthTokenStore.needsRefresh(credential) else { return credential }
        let refreshed = try await refresher.refresh(credential)
        try await tokenStore.store(refreshed)
        return refreshed
    }

    /// Builds the `codex/responses` request with the required headers.
    ///
    /// Pure +
    /// static for unit testing (no network, no Keychain).
    public static func makeRequest(accessToken: String, accountId: String, body: Data) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = body
        return req
    }
}
