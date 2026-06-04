import Foundation
import Security

/// Thin facade over the macOS Keychain.
///
/// One instance per service id.
/// Used for cloud API keys (OpenAI, OpenRouter, Anthropic, etc.) and any other
/// secrets that should not live in plaintext UserDefaults.
public struct KeychainSecrets: Sendable {
    public let service: String

    public init(service: String = "app.trace") {
        self.service = service
    }

    /// Stores or replaces a string value under `account`.
    public func save(account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw TraceError.configInvalid(field: "keychain.value", reason: "utf8 encoding failed")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        // Either the item doesn't exist yet (errSecItemNotFound), or it exists but
        // THIS code identity can't update it — which happens after the dev app is
        // re-signed, since the item was created under the old signature. In the
        // latter case, drop the stale item so we can re-add a fresh one we own,
        // instead of failing the save silently.
        if updateStatus != errSecItemNotFound {
            SecItemDelete(query as CFDictionary)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TraceError.storageFailed(
                reason: "Keychain save failed (update \(updateStatus), add \(addStatus))")
        }
    }

    /// Returns the string value for `account`, or `nil` if not found.
    public func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
                throw TraceError.storageFailed(reason: "Keychain item is not utf8 string")
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw TraceError.storageFailed(reason: "Keychain read failed: \(status)")
        }
    }

    /// Whether a non-empty value is stored for `account` — the one synchronous
    /// presence check the settings cards and the provider catalog share, so the
    /// triple-optional unwrap lives in exactly one place.
    public func hasValue(account: String) -> Bool {
        ((try? load(account: account)) ?? nil)?.isEmpty == false
    }

    /// Deletes the entry for `account` if it exists.
    ///
    /// No-op if missing.
    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TraceError.storageFailed(reason: "Keychain delete failed: \(status)")
        }
    }
}
