import Foundation

/// Pure validators that screen a `SparkleConfig` for the obvious mistakes
/// before it ever reaches the Sparkle framework.
///
/// Used at launch time so we
/// can fail loudly instead of letting Sparkle silently ignore a bad config.
public enum AppcastValidation {

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case insecureFeedURL(host: String)
        case unsupportedScheme(scheme: String)
        case publicKeyEmpty
        case publicKeyPlaceholder
        case publicKeyMalformed(reason: String)
        case scheduledCheckIntervalTooShort(TimeInterval)

        public var description: String {
            switch self {
            case .insecureFeedURL(let host):
                return "Sparkle feed must be HTTPS; got insecure host \(host)"
            case .unsupportedScheme(let scheme):
                return "Sparkle feed scheme not supported: \(scheme)"
            case .publicKeyEmpty:
                return "Sparkle public key is empty"
            case .publicKeyPlaceholder:
                return "Sparkle public key is still the placeholder shipped in BootstrapConfig.json"
            case .publicKeyMalformed(let reason):
                return "Sparkle public key invalid: \(reason)"
            case .scheduledCheckIntervalTooShort(let value):
                return "SUScheduledCheckInterval=\(value) is below the 60-second floor"
            }
        }
    }

    /// Returns `[]` when the config is acceptable, otherwise every problem
    /// observed.
    ///
    /// Multi-error return lets the caller surface the full set in
    /// one log line.
    public static func validate(_ config: SparkleConfig) -> [Failure] {
        var failures: [Failure] = []

        let scheme = config.feedURL.scheme?.lowercased() ?? ""
        switch scheme {
        case "https":
            break
        case "http":
            failures.append(.insecureFeedURL(host: config.feedURL.host ?? "<unknown>"))
        case "":
            failures.append(.unsupportedScheme(scheme: "<empty>"))
        default:
            failures.append(.unsupportedScheme(scheme: scheme))
        }

        if config.publicEDKey.isEmpty {
            failures.append(.publicKeyEmpty)
        } else if config.publicEDKey.contains("REPLACE_WITH") {
            failures.append(.publicKeyPlaceholder)
        } else {
            // EdDSA public keys are 32 raw bytes => 44-character base64 with one
            // padding char. We accept 43 (no padding) and 44 (with padding).
            let trimmed = config.publicEDKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count != 43 && trimmed.count != 44 {
                failures.append(
                    .publicKeyMalformed(reason: "expected 43- or 44-character base64, got \(trimmed.count)"))
            } else if Data(base64Encoded: padBase64(trimmed)) == nil {
                failures.append(.publicKeyMalformed(reason: "not valid base64"))
            }
        }

        if config.scheduledCheckInterval < 60 {
            failures.append(.scheduledCheckIntervalTooShort(config.scheduledCheckInterval))
        }

        return failures
    }

    private static func padBase64(_ input: String) -> String {
        let remainder = input.count % 4
        if remainder == 0 { return input }
        return input + String(repeating: "=", count: 4 - remainder)
    }
}
