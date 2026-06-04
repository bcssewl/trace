import Foundation
import XCTest

@testable import SharedCore

/// BAS-37 — ChatGPT/Codex OAuth + the ChatGPT-backend Responses API.
///
/// Pinned:
/// PKCE (S256, RFC 7636 vector), JWT payload + account-id decode, the OAuth
/// authorize/token/refresh request builders, the loopback callback parser, the
/// Responses request body + SSE decoding, and the provider's request headers.
final class OAuthCodexTests: XCTestCase {

    // MARK: PKCE / JWT

    func testS256ChallengeMatchesRFC7636Vector() {
        // RFC 7636 Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthPKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierIsURLSafeAndLongEnough() {
        let verifier = OAuthPKCE.makeVerifier(randomBytes: Data((0..<32).map { UInt8($0) }))
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertFalse(verifier.contains("+"))
        XCTAssertFalse(verifier.contains("/"))
        XCTAssertFalse(verifier.contains("="))
    }

    func testDecodeJWTPayloadAndAccountId() throws {
        let payload: [String: Any] = [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct_xyz"],
            "email": "u@example.com",
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let b64 = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJub25lIn0.\(b64).sig"
        let decoded = try XCTUnwrap(OAuthPKCE.decodeJWTPayload(jwt))
        XCTAssertEqual(decoded["email"] as? String, "u@example.com")
        XCTAssertEqual(CodexAuth.chatgptAccountId(fromIDToken: jwt), "acct_xyz")
    }

    // MARK: OAuth request builders

    func testAuthorizeURLCarriesPKCEAndCodexParams() throws {
        let url = CodexAuth.authorizeURL(challenge: "CHALLENGE", state: "STATE")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(comps.host, "auth.openai.com")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(items["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertEqual(items["code_challenge"], "CHALLENGE")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "STATE")
        XCTAssertEqual(items["originator"], "codex_cli_rs")
        XCTAssertEqual(items["scope"], "openid profile email offline_access")
    }

    func testTokenExchangeBodyIsFormEncoded() {
        let body = CodexAuth.tokenExchangeBody(code: "CODE", verifier: "VERIFIER")
        let pairs = Dictionary(
            uniqueKeysWithValues: body.split(separator: "&").map { pair -> (String, String) in
                let kv = pair.split(separator: "=", maxSplits: 1)
                return (String(kv[0]), kv.count > 1 ? String(kv[1]) : "")
            })
        XCTAssertEqual(pairs["grant_type"], "authorization_code")
        XCTAssertEqual(pairs["code"], "CODE")
        XCTAssertEqual(pairs["code_verifier"], "VERIFIER")
        XCTAssertEqual(pairs["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
    }

    func testRefreshBodyIsJSON() throws {
        // The plan specifies JSON for refresh (only the code exchange is form-encoded).
        let data = CodexAuth.refreshBody(refreshToken: "RT")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(json["refresh_token"] as? String, "RT")
        XCTAssertEqual(json["client_id"] as? String, "app_EMoamEEZ73f0CkXaXp7hrann")
    }

    // MARK: loopback callback parsing

    func testParseCallbackExtractsCodeAndState() {
        let line = "GET /auth/callback?code=abc123&state=xyz HTTP/1.1"
        let parsed = OAuthCallbackListener.parseCallback(requestLine: line)
        XCTAssertEqual(parsed?.code, "abc123")
        XCTAssertEqual(parsed?.state, "xyz")
    }

    func testParseCallbackRejectsWrongPathOrMissingCode() {
        XCTAssertNil(OAuthCallbackListener.parseCallback(requestLine: "GET /favicon.ico HTTP/1.1"))
        XCTAssertNil(OAuthCallbackListener.parseCallback(requestLine: "GET /auth/callback?state=xyz HTTP/1.1"))
    }

    // MARK: token store refresh policy

    func testNeedsRefreshHonoursSkew() {
        let cred = OAuthCredential(
            accessToken: "a", refreshToken: "r", idToken: nil,
            expiresAt: Date(timeIntervalSince1970: 1_000), accountId: nil)
        // 5-min skew: refresh when within 300s of expiry.
        XCTAssertTrue(OAuthTokenStore.needsRefresh(cred, now: Date(timeIntervalSince1970: 800), skew: 300))
        XCTAssertFalse(OAuthTokenStore.needsRefresh(cred, now: Date(timeIntervalSince1970: 600), skew: 300))
        XCTAssertTrue(OAuthTokenStore.needsRefresh(cred, now: Date(timeIntervalSince1970: 1_500), skew: 300))
    }

    func testOAuthCredentialRoundTrips() throws {
        let cred = OAuthCredential(
            accessToken: "at", refreshToken: "rt", idToken: "it",
            expiresAt: Date(timeIntervalSince1970: 42), accountId: "acct")
        let data = try JSONEncoder().encode(cred)
        XCTAssertEqual(try JSONDecoder().decode(OAuthCredential.self, from: data), cred)
    }

    // MARK: Responses API wire

    func testResponsesBodyInvariants() throws {
        let request = LLMRequest(
            messages: [LLMMessage(role: .system, content: "Be brief."), LLMMessage(role: .user, content: "Hi")],
            taskClass: .libraryQA
        )
        let data = try ResponsesAPI.requestBody(request, model: "gpt-5.1")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-5.1")
        XCTAssertEqual(json["store"] as? Bool, false, "Codex requires store:false")
        XCTAssertEqual(json["stream"] as? Bool, true, "Codex Responses is stream-only")
        XCTAssertEqual(json["instructions"] as? String, "Be brief.")
        XCTAssertEqual(json["include"] as? [String], ["reasoning.encrypted_content"])
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1, "only non-system turns go in input")
        XCTAssertEqual(input[0]["role"] as? String, "user")
    }

    func testResponsesBodyDefaultsInstructionsWhenNoSystem() throws {
        let request = LLMRequest(messages: [LLMMessage(role: .user, content: "Hi")], taskClass: .libraryQA)
        let data = try ResponsesAPI.requestBody(request, model: "m")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let instructions = try XCTUnwrap(json["instructions"] as? String)
        XCTAssertFalse(instructions.isEmpty, "Codex rejects an empty instructions field")
    }

    func testResponsesSSEDecoding() {
        XCTAssertEqual(
            ResponsesAPI.textDelta(
                from: SSEEvent(
                    event: "response.output_text.delta", data: #"{"type":"response.output_text.delta","delta":"Hel"}"#)),
            "Hel"
        )
        XCTAssertNil(
            ResponsesAPI.textDelta(from: SSEEvent(event: "response.created", data: #"{"type":"response.created"}"#)))
        XCTAssertTrue(
            ResponsesAPI.isCompleted(SSEEvent(event: "response.completed", data: #"{"type":"response.completed"}"#)))
        XCTAssertNotNil(
            ResponsesAPI.error(
                from: SSEEvent(
                    event: "response.failed",
                    data: #"{"type":"response.failed","response":{"error":{"message":"boom"}}}"#)))
    }

    // MARK: provider request headers

    func testCodexProviderRequestHeaders() {
        let req = CodexSubscriptionProvider.makeRequest(accessToken: "AT", accountId: "acct_1", body: Data("{}".utf8))
        XCTAssertEqual(req.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "chatgpt-account-id"), "acct_1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "OpenAI-Beta"), "responses=experimental")
        XCTAssertEqual(req.value(forHTTPHeaderField: "originator"), "codex_cli_rs")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }
}
