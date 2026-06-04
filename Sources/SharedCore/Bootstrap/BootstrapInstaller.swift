import Foundation

/// Idempotent installer that lays down the default configuration produced by
/// `BootstrapConfig` on first launch.
///
/// Subsequent launches are a no-op unless
/// the schema version embedded in the config increases.
///
/// The installer writes into three tables:
///
///   - `bootstrap_state` (schema v17) — sentinel `(installed_at, version)`
///     row; presence + matching version short-circuits the install.
///   - `settings_kv` (schema v13) — JSON-encoded blobs for hotkeys, Sparkle
///     defaults, storage paths, model caches, diagnostics.
///   - `routing_overrides` (schema v11) — per-task-class route preferences.
///     Embedding tasks share the same table by prefixing the task-class
///     name with `embeddings.`.
public struct BootstrapInstaller: Sendable {

    public enum Outcome: Sendable, Equatable {
        case freshInstall(version: Int)
        case alreadyInstalled(version: Int)
        case upgraded(from: Int, to: Int)
    }

    private let database: SqliteDatabase
    private let config: BootstrapConfig
    private let clock: @Sendable () -> Date

    public init(
        database: SqliteDatabase,
        config: BootstrapConfig = .bundled,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.config = config
        self.clock = clock
    }

    /// Runs the installer.
    ///
    /// Returns whether the install was fresh, upgraded,
    /// or short-circuited because the matching version was already present.
    public func installIfNeeded() async throws -> Outcome {
        let existing = try await readInstalledVersion()
        if let existing, existing >= config.schemaVersion {
            Loggers.bootstrap.info(
                "BootstrapConfig already installed at version \(existing) (config asks for \(self.config.schemaVersion)). Skipping."
            )
            return .alreadyInstalled(version: existing)
        }

        try await database.transaction {
            try await self.seedSettings()
            try await self.seedRoutingOverrides()
            try await self.recordInstall()
        }

        if let existing {
            Loggers.bootstrap.info("BootstrapConfig upgraded \(existing) -> \(self.config.schemaVersion)")
            return .upgraded(from: existing, to: config.schemaVersion)
        }
        Loggers.bootstrap.info("BootstrapConfig fresh install at version \(self.config.schemaVersion)")
        return .freshInstall(version: config.schemaVersion)
    }

    // MARK: - Sentinel

    private func readInstalledVersion() async throws -> Int? {
        try await database.withStatement(sql: "SELECT version FROM bootstrap_state ORDER BY version DESC LIMIT 1") {
            stmt -> Int? in
            let res = try stmt.step()
            return res == .row ? stmt.columnInt(at: 0) : nil
        }
    }

    private func recordInstall() async throws {
        let now = Int64(clock().timeIntervalSince1970)
        try await database.withStatement(
            sql: "INSERT INTO bootstrap_state (version, installed_at) VALUES (?, ?)"
        ) { stmt in
            try stmt.bind(int: config.schemaVersion, at: 1)
            try stmt.bind(int64: now, at: 2)
            _ = try stmt.step()
        }
    }

    // MARK: - settings_kv

    private func seedSettings() async throws {
        let encoder = makeEncoder()
        try await upsertSetting(key: "bootstrap.hotkeys", value: try encode(config.hotkeys, using: encoder))
        try await upsertSetting(key: "bootstrap.sparkle", value: try encode(config.sparkle, using: encoder))
        try await upsertSetting(key: "bootstrap.storage", value: try encode(config.storage, using: encoder))
        try await upsertSetting(key: "bootstrap.modelCaches", value: try encode(config.modelCaches, using: encoder))
        try await upsertSetting(key: "bootstrap.diagnostics", value: try encode(config.diagnostics, using: encoder))
        try await upsertSetting(
            key: "bootstrap.schemaVersion",
            value: String(config.schemaVersion)
        )
    }

    private func upsertSetting(key: String, value: String) async throws {
        let now = Int64(clock().timeIntervalSince1970)
        try await database.withStatement(
            sql: """
                INSERT INTO settings_kv (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """
        ) { stmt in
            try stmt.bind(text: key, at: 1)
            try stmt.bind(text: value, at: 2)
            try stmt.bind(int64: now, at: 3)
            _ = try stmt.step()
        }
    }

    // MARK: - routing_overrides

    private func seedRoutingOverrides() async throws {
        for (taskClass, route) in config.llmRoutes {
            try await upsertRoute(
                taskKey: taskClass.rawValue,
                provider: route.provider.rawValue,
                model: route.model
            )
        }
        for (taskClass, route) in config.embeddingRoutes {
            try await upsertRoute(
                taskKey: "embeddings.\(taskClass.rawValue)",
                provider: route.provider.rawValue,
                model: route.model
            )
        }
    }

    private func upsertRoute(taskKey: String, provider: String, model: String) async throws {
        let now = Int64(clock().timeIntervalSince1970)
        try await database.withStatement(
            sql: """
                INSERT INTO routing_overrides (task_class, provider, model, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(task_class) DO UPDATE SET
                    provider = excluded.provider,
                    model = excluded.model,
                    updated_at = excluded.updated_at
                """
        ) { stmt in
            try stmt.bind(text: taskKey, at: 1)
            try stmt.bind(text: provider, at: 2)
            try stmt.bind(text: model, at: 3)
            try stmt.bind(int64: now, at: 4)
            _ = try stmt.step()
        }
    }

    // MARK: - Helpers

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func encode<T: Encodable>(_ value: T, using encoder: JSONEncoder) throws -> String {
        let data = try encoder.encode(value)
        guard let str = String(data: data, encoding: .utf8) else {
            throw TraceError.storageFailed(reason: "bootstrap encode produced non-utf8 data")
        }
        return str
    }
}
