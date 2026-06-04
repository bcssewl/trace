import Foundation

public struct Migration: Sendable, Hashable {
    public let version: Int
    public let name: String
    public let sql: String

    public init(version: Int, name: String, sql: String) {
        precondition(version > 0, "Migration versions must be > 0")
        self.version = version
        self.name = name
        self.sql = sql
    }
}

public struct MigrationManager: Sendable {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) {
        self.database = database
    }

    public func bootstrap() async throws {
        try await database.exec(
            sql: """
                    CREATE TABLE IF NOT EXISTS _migrations (
                        version    INTEGER PRIMARY KEY,
                        name       TEXT NOT NULL,
                        applied_at INTEGER NOT NULL
                    )
                """)
    }

    public func currentVersion() async throws -> Int {
        try await database.scalarInt(sql: "SELECT COALESCE(MAX(version), 0) FROM _migrations")
    }

    /// Returns the set of every version recorded in `_migrations`.
    ///
    /// Used to
    /// drive idempotent apply logic — we run any migration whose version
    /// isn't yet in the table, regardless of MAX(version). This fixes the
    /// bug where adding migration N retroactively (after a higher-versioned
    /// migration was already applied via a separate schema file) was silently
    /// skipped by the previous `version > MAX` check.
    public func appliedVersions() async throws -> Set<Int> {
        let rows = try await database.withStatement(
            sql: "SELECT version FROM _migrations"
        ) { stmt -> [Int] in
            var out: [Int] = []
            while case .row = try stmt.step() {
                out.append(stmt.columnInt(at: 0))
            }
            return out
        }
        return Set(rows)
    }

    public func apply(migrations input: [Migration]) async throws {
        guard !input.isEmpty else { return }

        let versions = input.map(\.version)
        let uniqueVersions = Set(versions)
        guard versions.count == uniqueVersions.count else {
            throw TraceError.storageFailed(reason: "Duplicate migration versions: \(versions)")
        }

        let sorted = input.sorted { $0.version < $1.version }
        let already = try await appliedVersions()

        for migration in sorted where !already.contains(migration.version) {
            let priorVersion = try await currentVersion()
            try await applyOne(migration, fromVersion: priorVersion)
        }
    }

    private func applyOne(_ m: Migration, fromVersion: Int) async throws {
        Loggers.storage.info("Applying migration v\(m.version) \(m.name, privacy: .public)")
        do {
            try await database.transaction {
                try await database.exec(sql: m.sql)
                try await database.withStatement(
                    sql: "INSERT INTO _migrations (version, name, applied_at) VALUES (?, ?, ?)"
                ) { stmt in
                    try stmt.bind(int: m.version, at: 1)
                    try stmt.bind(text: m.name, at: 2)
                    try stmt.bind(int64: Int64(Date().timeIntervalSince1970), at: 3)
                    _ = try stmt.step()
                }
            }
        } catch {
            Loggers.storage.error("Migration v\(m.version) failed: \(String(describing: error), privacy: .public)")
            throw TraceError.migrationFailed(
                fromVersion: fromVersion,
                toVersion: m.version,
                reason: String(describing: error)
            )
        }
    }
}
