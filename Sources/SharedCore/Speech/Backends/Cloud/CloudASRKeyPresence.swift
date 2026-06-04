import Foundation

extension CloudASRProvider {
    /// The set of cloud-ASR providers (by `rawValue`) that currently have a key in
    /// the Keychain — the single probe shared by the Dictation-models cloud tab and
    /// the Meetings cloud picker, so a keyless provider isn't a silent dead-end.
    ///
    /// Fall-open on a thrown error: `KeychainSecrets.load` returns `nil` for a clean
    /// miss and only THROWS on a real Keychain failure (locked / auth denied). A
    /// thrown error therefore keeps the provider in the set — we never silently
    /// demote a provider to "no key" on a transient failure and wrongly tell the
    /// user they have no key.
    public static func keyedProviders(keychain: KeychainSecrets = KeychainSecrets()) -> Set<String> {
        var present: Set<String> = []
        for provider in allCases {
            let account = CloudASRBackend.endpoints(for: provider).keychainAccount
            do {
                if let key = try keychain.load(account: account), !key.isEmpty {
                    present.insert(provider.rawValue)
                }
            } catch {
                present.insert(provider.rawValue)
            }
        }
        return present
    }
}
