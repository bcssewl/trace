import Foundation

/// Driver-side surface implemented by the Sparkle.framework adapter that
/// lives outside SharedCore.
///
/// Optional methods carry default implementations
/// so existing test stubs (which only need `checkForUpdates`) keep compiling.
public protocol UpdaterDriving: AnyObject, Sendable {
    func checkForUpdates()
    func setAutomaticallyChecksForUpdates(_ enabled: Bool)
    func setFeedURL(_ url: URL)
    var lastUpdateCheckDate: Date? { get }
}

extension UpdaterDriving {
    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {}
    public func setFeedURL(_ url: URL) {}
    public var lastUpdateCheckDate: Date? { nil }
}

/// Thin coordinator between the rest of the app and the Sparkle framework.
///
/// Holds the `SparkleConfig` snapshot and forwards user-initiated update
/// checks to whichever driver was injected (real Sparkle `SPUStandardUpdaterController`
/// in production; a stub in unit tests).
public final class UpdaterController: @unchecked Sendable {

    private weak var driver: (any UpdaterDriving)?
    private let configuration: SparkleConfig?

    public init(driver: any UpdaterDriving, configuration: SparkleConfig? = nil) {
        self.driver = driver
        self.configuration = configuration
        if let configuration {
            driver.setFeedURL(configuration.feedURL)
            driver.setAutomaticallyChecksForUpdates(configuration.enableAutomaticChecks)
            BridgeLogger.sparkle.info(
                "UpdaterController configured: feed=\(configuration.feedURL.absoluteString, privacy: .public), auto=\(configuration.enableAutomaticChecks, privacy: .public)"
            )
        }
    }

    public func checkForUpdates() {
        BridgeLogger.sparkle.info("User requested update check")
        driver?.checkForUpdates()
    }

    public func setAutomaticChecks(enabled: Bool) {
        driver?.setAutomaticallyChecksForUpdates(enabled)
    }

    public func overrideFeedURL(_ url: URL) {
        BridgeLogger.sparkle.info("Operator overrode feed URL to \(url.absoluteString, privacy: .public)")
        driver?.setFeedURL(url)
    }

    public var lastCheckDate: Date? { driver?.lastUpdateCheckDate }

    /// The configuration this controller was constructed with. `nil` when the
    /// caller wired up a driver without going through `SparkleConfig`.
    public var sparkleConfig: SparkleConfig? { configuration }
}
