import Foundation
import SharedCore
import Sparkle

/// Sparkle.framework adapter that implements `SharedCore.UpdaterDriving`.
///
/// Lives in AppShell so SharedCore stays free of the Sparkle binary
/// dependency (tests can still drive `UpdaterController` with a stub).
///
/// ## Isolation
/// Sparkle 2's `SPUUpdater`, `SPUStandardUpdaterController`, and
/// `SPUUpdaterDelegate` are all `@MainActor` in the current Swift interface
/// (every property/method "must be called on the main thread"). This adapter
/// is therefore `@MainActor`, so every touch of the underlying Sparkle objects
/// is legitimately main-actor isolated rather than reaching into them from a
/// nonisolated context.
///
/// `UpdaterDriving` itself is a *nonisolated*, `Sendable` protocol because
/// `UpdaterController` (and its unit-test stub) construct and call drivers off
/// the main actor. We bridge the two worlds by satisfying each requirement with
/// a `nonisolated` witness that hops onto the main actor before touching
/// Sparkle. The hop is real (not a `MainActor.assumeIsolated` lie): when already
/// on the main thread we adopt the existing isolation; otherwise we block via
/// `DispatchQueue.main.sync`.
///
/// ## Feed URL
/// The feed URL is supplied at runtime from a validated `BootstrapConfig`, not
/// statically in Info.plist, so we implement `SPUUpdaterDelegate`'s
/// `feedURLString(for:)` to vend it dynamically and call
/// `clearFeedURLFromUserDefaults()` once at startup to drop any stale value a
/// previous build may have written via the deprecated `-setFeedURL:`.
@MainActor
public final class SparkleUpdaterAdapter: NSObject, SPUUpdaterDelegate {

    /// Implicitly-unwrapped because Sparkle only accepts the updater delegate
    /// through `SPUStandardUpdaterController`'s initializer (there is no settable
    /// `SPUUpdater.delegate`), and that initializer needs a fully-initialized
    /// `self`. We therefore assign it after `super.init()`.
    private var controller: SPUStandardUpdaterController!

    /// Runtime feed URL handed in by `UpdaterController`.
    ///
    /// Read by the
    /// `@MainActor` `feedURLString(for:)` delegate callback, so it stays
    /// main-actor isolated.
    private var feedURLOverride: URL?

    public override init() {
        super.init()

        // `startingUpdater: false` so the controller is fully wired (delegate
        // installed, stale stored feed cleared) before the first scheduled check
        // fires and queries `feedURLString(for:)`.
        //
        // The delegate must be passed here — `SPUUpdater` exposes no settable
        // `delegate` property — and it is held weakly, so AppDelegate is
        // responsible for keeping this adapter alive (it does).
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller

        // Migrate off the deprecated `-setFeedURL:` path: clear any feed URL a
        // prior build persisted into the host bundle's user defaults so Sparkle
        // doesn't silently prefer it over `feedURLString(for:)`. Returns the
        // previously stored URL, which we don't need.
        _ = controller.updater.clearFeedURLFromUserDefaults()

        controller.startUpdater()
    }

    // MARK: - SPUUpdaterDelegate

    /// Dynamically supplies the runtime feed URL.
    ///
    /// Sparkle prefers this over any
    /// stored/Info.plist value, which is exactly what we want for a feed that's
    /// only known after bootstrap validation. This delegate method is
    /// `@MainActor` (the whole `SPUUpdaterDelegate` protocol is), so reading the
    /// main-actor-isolated `feedURLOverride` here is in-isolation.
    public func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLOverride?.absoluteString
    }

    // MARK: - Main-actor implementations

    private func applyFeedURL(_ url: URL) {
        feedURLOverride = url
    }

    private func applyAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    private func performCheckForUpdates() {
        controller.checkForUpdates(nil)
    }

    private var currentLastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    public var underlyingUpdater: SPUUpdater {
        controller.updater
    }
}

// MARK: - UpdaterDriving (nonisolated bridge)

extension SparkleUpdaterAdapter: UpdaterDriving {

    public nonisolated func checkForUpdates() {
        runOnMain { $0.performCheckForUpdates() }
    }

    public nonisolated func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        runOnMain { $0.applyAutomaticChecks(enabled) }
    }

    public nonisolated func setFeedURL(_ url: URL) {
        runOnMain { $0.applyFeedURL(url) }
    }

    public nonisolated var lastUpdateCheckDate: Date? {
        runOnMain { $0.currentLastUpdateCheckDate }
    }
}

// MARK: - Main-actor bridge

extension SparkleUpdaterAdapter {

    /// Runs `body` on the main actor and returns its result synchronously.
    ///
    /// `UpdaterDriving`'s requirements are nonisolated, but the underlying
    /// Sparkle objects are `@MainActor`, so we must reach the main actor before
    /// touching them. We do it honestly:
    ///
    /// * Already on the main thread → `MainActor.assumeIsolated` adopts the
    ///   isolation we provably already have (no thread hop, no lie). This is the
    ///   hot path: every real call site flows through the `@MainActor`
    ///   `AppDelegate`.
    /// * Off the main thread (e.g. a unit-test or future background caller) →
    ///   block on `DispatchQueue.main.sync`, which actually moves execution to
    ///   the main thread before adopting the isolation.
    private nonisolated func runOnMain<T: Sendable>(
        _ body: @Sendable @MainActor (SparkleUpdaterAdapter) -> T
    ) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body(self) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { body(self) }
        }
    }
}
