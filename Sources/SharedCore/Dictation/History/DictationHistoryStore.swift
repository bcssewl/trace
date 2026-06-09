import Foundation

/// Persists every dictation cycle to the SQLite `dictations` table.
///
/// Reads back chronologically (newest first) for the Library → Dictation
/// History view. Records keep both the raw ASR text and the LLM-cleaned text
/// so the user can re-process with a different mode prompt without re-running
/// audio capture.
public actor DictationHistoryStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) {
        self.database = database
    }

    public func insert(_ record: DictationRecord) async throws {
        let id = record.id
        let projectIDText = record.projectID?.uuidString
        let modeName = record.modeName
        let bundleID = record.bundleID
        let rawText = record.rawText
        let cleanedText = record.cleanedText
        let inserted = record.inserted ? 1 : 0
        let durationMs = record.durationMs
        let startedAt = Int64(record.startedAt)
        let recovered = record.recovered ? 1 : 0

        try await database.withStatement(
            sql: """
                INSERT INTO dictations (
                    id, project_id, mode_name, bundle_id,
                    raw_text, cleaned_text, inserted, duration_ms, started_at, recovered
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
        ) { stmt in
            try stmt.bind(text: id, at: 1)
            try stmt.bind(optionalText: projectIDText, at: 2)
            try stmt.bind(optionalText: modeName, at: 3)
            try stmt.bind(optionalText: bundleID, at: 4)
            try stmt.bind(text: rawText, at: 5)
            try stmt.bind(text: cleanedText, at: 6)
            try stmt.bind(int: inserted, at: 7)
            try stmt.bind(int: durationMs, at: 8)
            try stmt.bind(int64: startedAt, at: 9)
            try stmt.bind(int: recovered, at: 10)
            _ = try stmt.step()
        }
    }

    public func record(id: String) async throws -> DictationRecord? {
        try await database.withStatement(
            sql: """
                SELECT id, project_id, mode_name, bundle_id, raw_text, cleaned_text,
                       inserted, duration_ms, started_at, recovered
                FROM dictations
                WHERE id = ?
                """
        ) { stmt -> DictationRecord? in
            try stmt.bind(text: id, at: 1)
            guard case .row = try stmt.step() else { return nil }
            return Self.decode(from: stmt)
        }
    }

    /// Recent dictations, newest-first.
    ///
    /// Pass `projectID` to scope to one project's
    /// dictations (the per-project Dictation view); `nil` lists every record for the
    /// global Library → All dictation page.
    public func recent(limit: Int = 50, projectID: UUID? = nil) async throws -> [DictationRecord] {
        let cappedLimit = max(1, min(limit, 500))
        let whereClause = projectID == nil ? "" : "WHERE project_id = ?"
        return try await database.withStatement(
            sql: """
                SELECT id, project_id, mode_name, bundle_id, raw_text, cleaned_text,
                       inserted, duration_ms, started_at, recovered
                FROM dictations
                \(whereClause)
                ORDER BY started_at DESC
                LIMIT ?
                """
        ) { stmt -> [DictationRecord] in
            var idx: Int32 = 1
            if let projectID {
                try stmt.bind(text: projectID.uuidString, at: idx)
                idx += 1
            }
            try stmt.bind(int: cappedLimit, at: idx)
            var out: [DictationRecord] = []
            while case .row = try stmt.step() {
                if let record = Self.decode(from: stmt) {
                    out.append(record)
                }
            }
            return out
        }
    }

    public func delete(id: String) async throws {
        // Purge the keyword-search index row in the same transaction — without
        // this a deleted dictation ghosts in search until the next launch
        // reconcile sweeps it.
        try await database.transaction {
            try await database.withStatement(
                sql: "DELETE FROM entry_fts WHERE source = 'dictation' AND item_id = ?"
            ) { stmt in
                try stmt.bind(text: id, at: 1)
                _ = try stmt.step()
            }
            try await database.withStatement(sql: "DELETE FROM dictations WHERE id = ?") { stmt in
                try stmt.bind(text: id, at: 1)
                _ = try stmt.step()
            }
        }
    }

    public func count() async throws -> Int {
        try await database.scalarInt(sql: "SELECT COUNT(*) FROM dictations")
    }

    private static func decode(from stmt: SqliteStatement) -> DictationRecord? {
        guard let id = stmt.columnText(at: 0) else { return nil }
        let projectIDText = stmt.columnText(at: 1)
        let projectID = projectIDText.flatMap(UUID.init(uuidString:))
        let modeName = stmt.columnText(at: 2)
        let bundleID = stmt.columnText(at: 3)
        let rawText = stmt.columnText(at: 4) ?? ""
        let cleanedText = stmt.columnText(at: 5) ?? ""
        let inserted = stmt.columnInt(at: 6) != 0
        let durationMs = stmt.columnInt(at: 7)
        let startedAt = TimeInterval(stmt.columnInt64(at: 8))
        let recovered = stmt.columnInt(at: 9) != 0
        return DictationRecord(
            id: id,
            projectID: projectID,
            modeName: modeName,
            bundleID: bundleID,
            rawText: rawText,
            cleanedText: cleanedText,
            inserted: inserted,
            durationMs: durationMs,
            startedAt: startedAt,
            recovered: recovered
        )
    }
}
