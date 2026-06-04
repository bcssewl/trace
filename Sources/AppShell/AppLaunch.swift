import Foundation
import SharedCore

/// Top-level coordinator responsible for bringing the app online.
///
///   1. Resolves the `BootstrapConfig` (bundled defaults overridden by
///      `BootstrapConfig.json` if the operator dropped one in Resources).
///   2. Opens the SQLite database at the configured path, runs the v1
///      schema migrations, then runs the v17 sentinel migration.
///   3. Runs `BootstrapInstaller.installIfNeeded` to seed the routing
///      override table on first launch.
///   4. Builds a validated `SparkleConfig` snapshot for the UI layer.
///
/// The launch coordinator is intentionally framework-free so unit tests can
/// drive the full sequence against a temp-dir SQLite database without
/// touching Sparkle.framework.
public struct AppLaunch: Sendable {

    public struct Result: Sendable {
        public let database: SqliteDatabase
        public let config: BootstrapConfig
        public let installerOutcome: BootstrapInstaller.Outcome
        public let sparkleConfig: SparkleConfig?
        public let sparkleValidationFailures: [AppcastValidation.Failure]

        public init(
            database: SqliteDatabase,
            config: BootstrapConfig,
            installerOutcome: BootstrapInstaller.Outcome,
            sparkleConfig: SparkleConfig?,
            sparkleValidationFailures: [AppcastValidation.Failure]
        ) {
            self.database = database
            self.config = config
            self.installerOutcome = installerOutcome
            self.sparkleConfig = sparkleConfig
            self.sparkleValidationFailures = sparkleValidationFailures
        }
    }

    public init() {}

    /// Runs the full launch sequence. The optional arguments are test seams:
    ///
    ///   - `bundle` — where to look for `BootstrapConfig.json`.
    ///   - `overrideConfig` — substitutes the resolved config wholesale.
    ///   - `databasePath` — pins the SQLite file location (otherwise the
    ///     configured path is expanded with `~`).
    public func boot(
        bundle: Bundle = .main,
        overrideConfig: BootstrapConfig? = nil,
        databasePath: URL? = nil
    ) async throws -> Result {
        let resolved = BootstrapConfig.resolved(override: overrideConfig, bundle: bundle)
        Loggers.bootstrap.info("Booting AppShell with config v\(resolved.schemaVersion)")

        let dbURL = databasePath ?? AppLaunch.expandTildePath(resolved.storage.sqlitePath)
        let database = try await SqliteDatabase.open(at: dbURL)

        // Apply the full schema through one idempotent seam (re-running on an
        // up-to-date database is a no-op).
        try await AppSchema.bootstrap(database: database)

        let installer = BootstrapInstaller(database: database, config: resolved)
        let outcome = try await installer.installIfNeeded()

        let sparkle: SparkleConfig?
        let failures: [AppcastValidation.Failure]

        if let fromBundle = SparkleConfig.fromBundle(bundle) {
            sparkle = fromBundle
            failures = AppcastValidation.validate(fromBundle)
        } else if let fromDefaults = SparkleConfig.from(resolved.sparkle) {
            sparkle = fromDefaults
            failures = AppcastValidation.validate(fromDefaults)
        } else {
            sparkle = nil
            failures = [.publicKeyEmpty]
        }

        if !failures.isEmpty {
            Loggers.bootstrap.error(
                "Sparkle config validation failures: \(failures.map(\.description).joined(separator: "; "), privacy: .public)"
            )
        }

        return Result(
            database: database,
            config: resolved,
            installerOutcome: outcome,
            sparkleConfig: sparkle,
            sparkleValidationFailures: failures
        )
    }

    /// Expands a leading `~` to the current user's home directory.
    ///
    /// Pure value
    /// transform, no I/O. Exposed `internal` so tests can verify the path
    /// behaviour without a full boot.
    static func expandTildePath(_ raw: String) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}
