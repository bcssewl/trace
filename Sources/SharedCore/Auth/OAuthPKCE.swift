import CryptoKit
import Foundation

/// PKCE (RFC 7636, S256) + JWT-payload decoding for the OAuth subscription flow
/// (BAS-37).
///
/// Pure + deterministic so the crypto is unit-testable against the RFC
/// vectors; no network or Keychain here.
public enum OAuthPKCE {

    /// A high-entropy `code_verifier` (base64url, unreserved, ≥43 chars).
    public static func makeVerifier(randomBytes: Data = OAuthPKCE.randomBytes(64)) -> String {
        base64URL(randomBytes)
    }

    /// An anti-CSRF `state` token.
    public static func makeState(randomBytes: Data = OAuthPKCE.randomBytes(32)) -> String {
        base64URL(randomBytes)
    }

    /// `code_challenge = BASE64URL(SHA256(ASCII(code_verifier)))`.
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Decodes a JWT's payload segment (base64url JSON) into a dictionary.
    public static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2,
            let data = base64URLDecode(String(segments[1])),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            // SecRandomCopyBytes essentially never fails, but never emit an
            // all-zero (predictable) verifier/state — fall back to the system CSPRNG.
            return Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
        }
        return Data(bytes)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
