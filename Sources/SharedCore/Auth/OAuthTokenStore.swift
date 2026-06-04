import Foundation

/// An OAuth credential persisted as JSON in the Keychain (BAS-37).
public struct OAuthCredential: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String?
    public var expiresAt: Date
    public var accountId: String?

    public init(accessToken: String, refreshToken: String, idToken: String?, expiresAt: Date, accountId: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.accountId = accountId
    }
}

/// Stores an `OAuthCredential` as JSON in the existing `KeychainSecrets` facade,
/// keyed by `account`, and decides when a proactive refresh is due (BAS-37).
public actor OAuthTokenStore {
    private let account: String
    private let keychain: KeychainSecrets

    public init(account: String, keychain: KeychainSecrets = KeychainSecrets()) {
        self.account = account
        self.keychain = keychain
    }

    /// The stored credential, or `nil` if absent / corrupt (graceful — the caller
    /// treats a corrupt blob as "signed out").
    public func current() throws -> OAuthCredential? {
        guard let json = try keychain.load(account: account), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthCredential.self, from: data)
    }

    public func store(_ credential: OAuthCredential) throws {
        let data = try JSONEncoder().encode(credential)
        try keychain.save(account: account, value: String(decoding: data, as: UTF8.self))
    }

    public func clear() throws {
        try keychain.delete(account: account)
    }

    /// Whether the access token should be refreshed now — true once we are within
    /// `skew` seconds of (or past) expiry.
    public nonisolated static func needsRefresh(
        _ credential: OAuthCredential,
        now: Date = Date(),
        skew: TimeInterval = 300
    ) -> Bool {
        credential.expiresAt.addingTimeInterval(-skew) <= now
    }
}
