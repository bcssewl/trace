import Foundation

/// ChatGPT / Codex OAuth constants + request builders (BAS-37).
///
/// Mirrors the
/// public Codex CLI flow: PKCE authorize → form-encoded code exchange → JSON
/// refresh, all at `auth.openai.com`, with the account id decoded from the
/// `id_token`. Builders are pure so they're unit-testable; the network calls
/// live in `CodexTokenRefresher` / the sign-in service.
public enum CodexAuth {
    /// The public Codex CLI client id (OpenAI sanctions subscription use in
    /// third-party tools that mirror this flow).
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let redirectURI = "http://localhost:1455/auth/callback"
    public static let scope = "openid profile email offline_access"
    public static let callbackPort: UInt16 = 1455
    /// Keychain account holding the persisted `OAuthCredential`.
    public static let keychainAccount = "openai-codex.oauth"

    public static func authorizeURL(challenge: String, state: String) -> URL {
        var comps = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        return comps.url!
    }

    /// Form-encoded body for the authorization-code exchange.
    public static func tokenExchangeBody(code: String, verifier: String) -> String {
        formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    /// JSON body for a token refresh.
    public static func refreshBody(refreshToken: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])) ?? Data()
    }

    /// The ChatGPT account id from the `id_token`'s `https://api.openai.com/auth` claim.
    public static func chatgptAccountId(fromIDToken idToken: String) -> String? {
        guard let payload = OAuthPKCE.decodeJWTPayload(idToken),
            let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    static func formEncode(_ params: [String: String]) -> String {
        params.map { "\($0.key)=\(formEscape($0.value))" }.joined(separator: "&")
    }

    static func formEscape(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The `oauth/token` response (shared by the code exchange + refresh).
struct CodexTokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let expires_in: Int?
}
