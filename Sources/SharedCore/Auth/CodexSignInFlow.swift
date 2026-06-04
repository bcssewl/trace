import Foundation

/// Drives the full ChatGPT/Codex sign-in (BAS-37): mint PKCE + state, open the
/// system browser at the authorize URL, run the loopback listener, verify the
/// returned `state`, exchange the code (form-encoded) for tokens, decode the
/// account id from the `id_token`, and persist the credential.
///
/// No embedded
/// WebView / helper process — `openURL` hands the URL to the system browser.
public struct CodexSignInFlow: Sendable {
    private let session: URLSession
    private let tokenStore: OAuthTokenStore

    public init(session: URLSession = .shared, tokenStore: OAuthTokenStore? = nil) {
        self.session = session
        self.tokenStore = tokenStore ?? OAuthTokenStore(account: CodexAuth.keychainAccount)
    }

    /// Runs the flow and returns the stored credential. `openURL` is injected so
    /// `SharedCore` stays AppKit-free (the app passes `NSWorkspace.shared.open`).
    @discardableResult
    public func signIn(openURL: @Sendable (URL) -> Void) async throws -> OAuthCredential {
        let verifier = OAuthPKCE.makeVerifier()
        let state = OAuthPKCE.makeState()
        let authorizeURL = CodexAuth.authorizeURL(challenge: OAuthPKCE.challenge(for: verifier), state: state)

        let listener = OAuthCallbackListener()
        openURL(authorizeURL)
        let callback = try await listener.waitForCallback()
        guard callback.state == state else {
            throw TraceError.configInvalid(field: "state", reason: "OAuth state mismatch — sign-in aborted for safety")
        }
        let credential = try await exchange(code: callback.code, verifier: verifier)
        try await tokenStore.store(credential)
        return credential
    }

    /// Exchanges the authorization code (form-encoded) for tokens.
    private func exchange(code: String, verifier: String) async throws -> OAuthCredential {
        var req = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(CodexAuth.tokenExchangeBody(code: code, verifier: verifier).utf8)
        let (data, response) = try await session.data(for: req)
        try OllamaProvider.validateHTTP(response, provider: "codex-oauth")
        let token = try JSONDecoder().decode(CodexTokenResponse.self, from: data)
        return OAuthCredential(
            accessToken: token.access_token,
            refreshToken: token.refresh_token ?? "",
            idToken: token.id_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600)),
            accountId: token.id_token.flatMap(CodexAuth.chatgptAccountId(fromIDToken:))
        )
    }
}
