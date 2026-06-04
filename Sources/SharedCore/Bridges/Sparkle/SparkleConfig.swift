import Foundation

/// Immutable snapshot of the Sparkle configuration that drives auto-updates.
///
/// The Swift code never imports the Sparkle framework directly; that wiring
/// lives in the `.app` bundle and is injected at launch through the
/// `UpdaterDriving` protocol. `SparkleConfig` is the value type that crosses
/// the boundary into framework code.
public struct SparkleConfig: Sendable, Hashable, Codable {

    public let feedURL: URL
    public let publicEDKey: String
    public let enableAutomaticChecks: Bool
    public let scheduledCheckInterval: TimeInterval

    public init(
        feedURL: URL,
        publicEDKey: String,
        enableAutomaticChecks: Bool,
        scheduledCheckInterval: TimeInterval
    ) {
        self.feedURL = feedURL
        self.publicEDKey = publicEDKey
        self.enableAutomaticChecks = enableAutomaticChecks
        self.scheduledCheckInterval = scheduledCheckInterval
    }

    public static let defaultScheduledCheckInterval: TimeInterval = 86_400

    /// Reads Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, optional
    /// `SUEnableAutomaticChecks`, optional `SUScheduledCheckInterval`) from
    /// the supplied bundle.
    ///
    /// Returns `nil` if any required key is missing or
    /// malformed; the caller is expected to log + skip Sparkle wiring.
    public static func fromBundle(_ bundle: Bundle = .main) -> SparkleConfig? {
        guard
            let feedString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let feedURL = URL(string: feedString),
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return nil
        }

        let enableAuto = (bundle.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool) ?? true
        let intervalRaw = bundle.object(forInfoDictionaryKey: "SUScheduledCheckInterval")
        let interval: TimeInterval
        if let n = intervalRaw as? NSNumber {
            interval = n.doubleValue
        } else {
            interval = SparkleConfig.defaultScheduledCheckInterval
        }

        return SparkleConfig(
            feedURL: feedURL,
            publicEDKey: publicKey,
            enableAutomaticChecks: enableAuto,
            scheduledCheckInterval: interval
        )
    }

    /// Convenience constructor that drops a `BootstrapConfig.SparkleDefaults`
    /// into a fully-typed `SparkleConfig`.
    ///
    /// Returns `nil` if the URL cannot be
    /// parsed, is missing a scheme, or has no host.
    public static func from(_ defaults: BootstrapConfig.SparkleDefaults) -> SparkleConfig? {
        guard let url = URL(string: defaults.feedURL),
            let scheme = url.scheme, !scheme.isEmpty,
            let host = url.host, !host.isEmpty
        else {
            return nil
        }
        return SparkleConfig(
            feedURL: url,
            publicEDKey: defaults.publicEDKey,
            enableAutomaticChecks: defaults.enableAutomaticChecks,
            scheduledCheckInterval: TimeInterval(defaults.scheduledCheckIntervalSeconds)
        )
    }
}
