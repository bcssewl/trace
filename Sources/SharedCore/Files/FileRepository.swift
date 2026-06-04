import Foundation

/// A row in the `files` table (schema v6).
public struct FileRecord: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let projectID: String?
    public let title: String?
    public let sourcePath: String
    public let transcriptPath: String?
    public let engine: String
    public let durationMs: Int64?
    public let status: FileBatchStatus
    public let errorReason: String?
    public let createdAt: Date
    public let completedAt: Date?
    /// What kind of media this row is (audio / video / mic-captured voice memo).
    public let kind: FileBatchJob.Kind
    /// How the job entered the pipeline (drag-drop, watched folder, iPhone Voice
    /// Memo sync, or live mic capture).
    ///
    /// Drives whether a row shows in the "Files"
    /// surface (`dragDrop`/`watchedFolder`) or the "Voice Memos" surface
    /// (`voiceMemoCapture`/`voiceMemosSync`).
    public let origin: FileBatchJob.Origin

    public init(
        id: String,
        projectID: String?,
        title: String?,
        sourcePath: String,
        transcriptPath: String?,
        engine: String,
        durationMs: Int64?,
        status: FileBatchStatus,
        errorReason: String?,
        createdAt: Date,
        completedAt: Date?,
        kind: FileBatchJob.Kind = .audio,
        origin: FileBatchJob.Origin = .dragDrop
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.sourcePath = sourcePath
        self.transcriptPath = transcriptPath
        self.engine = engine
        self.durationMs = durationMs
        self.status = status
        self.errorReason = errorReason
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.kind = kind
        self.origin = origin
    }

    /// `FileBatchJob.Origin`s shown under the "Files" surface.
    public static let fileOrigins: Set<FileBatchJob.Origin> = [.dragDrop, .watchedFolder]
    /// `FileBatchJob.Origin`s shown under the "Voice Memos" surface.
    public static let voiceMemoOrigins: Set<FileBatchJob.Origin> = [.voiceMemoCapture, .voiceMemosSync]
}

/// SQLite-backed actor that persists every `FileBatchJob` stage transition into
/// the schema-v6 `files` table. Operations are sequential `withStatement` calls
/// so the `SqliteDatabase` actor's exclusive serialization is preserved; no
/// transactions span actor hops.
public actor FileRepository {

    private let database: SqliteDatabase

    public init(database: SqliteDatabase) {
        self.database = database
    }

    /// Inserts a fresh row for a newly-queued job.
    ///
    /// Idempotent on the `id`
    /// primary key — if the same job is re-enqueued (e.g., after a crash
    /// recovery), the row is updated in place.
    public func insertQueued(
        job: FileBatchJob,
        engine: String,
        title: String? = nil,
        now: Date = Date()
    ) async throws {
        let sql = """
            INSERT INTO files (
                id, project_id, title, source_path, transcript_path,
                engine, duration_ms, status, error_reason,
                created_at, completed_at, kind, origin
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                project_id = excluded.project_id,
                title = excluded.title,
                source_path = excluded.source_path,
                transcript_path = NULL,
                engine = excluded.engine,
                duration_ms = NULL,
                status = excluded.status,
                error_reason = NULL,
                created_at = excluded.created_at,
                completed_at = NULL,
                kind = excluded.kind,
                origin = excluded.origin
            """
        try await database.withStatement(sql: sql) { stmt in
            try stmt.bind(text: job.id.uuidString, at: 1)
            try stmt.bind(optionalText: job.projectID, at: 2)
            try stmt.bind(optionalText: title ?? Self.defaultTitle(for: job), at: 3)
            try stmt.bind(text: job.sourceURL.path, at: 4)
            try stmt.bindNull(at: 5)
            try stmt.bind(text: engine, at: 6)
            try stmt.bindNull(at: 7)
            try stmt.bind(text: FileBatchStatus.queued.rawValue, at: 8)
            try stmt.bindNull(at: 9)
            try stmt.bind(int64: Int64(now.timeIntervalSince1970), at: 10)
            try stmt.bindNull(at: 11)
            try stmt.bind(text: job.kind.rawValue, at: 12)
            try stmt.bind(text: job.origin.rawValue, at: 13)
            _ = try stmt.step()
        }
    }

    /// Updates only the status column.
    public func updateStatus(id: UUID, status: FileBatchStatus) async throws {
        try await database.withStatement(
            sql: "UPDATE files SET status = ? WHERE id = ?"
        ) { stmt in
            try stmt.bind(text: status.rawValue, at: 1)
            try stmt.bind(text: id.uuidString, at: 2)
            _ = try stmt.step()
        }
    }

    /// Marks the job as completed: writes the transcript path, duration,
    /// status=completed, completed_at, and clears any stale error_reason.
    public func markCompleted(
        id: UUID,
        transcriptPath: String,
        durationMs: Int64?,
        now: Date = Date()
    ) async throws {
        let sql = """
            UPDATE files
               SET status = ?,
                   transcript_path = ?,
                   duration_ms = ?,
                   error_reason = NULL,
                   completed_at = ?
             WHERE id = ?
            """
        try await database.withStatement(sql: sql) { stmt in
            try stmt.bind(text: FileBatchStatus.completed.rawValue, at: 1)
            try stmt.bind(text: transcriptPath, at: 2)
            try stmt.bind(optionalInt64: durationMs, at: 3)
            try stmt.bind(int64: Int64(now.timeIntervalSince1970), at: 4)
            try stmt.bind(text: id.uuidString, at: 5)
            _ = try stmt.step()
        }
    }

    /// Records a failure and captures the reason text.
    public func markFailed(
        id: UUID,
        failure: FileBatchFailure,
        now: Date = Date()
    ) async throws {
        let sql = """
            UPDATE files
               SET status = ?,
                   error_reason = ?,
                   completed_at = ?
             WHERE id = ?
            """
        try await database.withStatement(sql: sql) { stmt in
            try stmt.bind(text: FileBatchStatus.failed.rawValue, at: 1)
            try stmt.bind(text: "[\(failure.stage.rawValue)] \(failure.reason)", at: 2)
            try stmt.bind(int64: Int64(now.timeIntervalSince1970), at: 3)
            try stmt.bind(text: id.uuidString, at: 4)
            _ = try stmt.step()
        }
    }

    /// Marks the job as cancelled.
    ///
    /// Uses the same completed_at timestamp column
    /// to record the cancellation moment; UI distinguishes via `status`.
    public func markCancelled(id: UUID, reason: String = "user cancelled", now: Date = Date()) async throws {
        let sql = """
            UPDATE files
               SET status = ?,
                   error_reason = ?,
                   completed_at = ?
             WHERE id = ?
            """
        try await database.withStatement(sql: sql) { stmt in
            try stmt.bind(text: FileBatchStatus.cancelled.rawValue, at: 1)
            try stmt.bind(text: reason, at: 2)
            try stmt.bind(int64: Int64(now.timeIntervalSince1970), at: 3)
            try stmt.bind(text: id.uuidString, at: 4)
            _ = try stmt.step()
        }
    }

    /// The column list shared by every `SELECT` so the `decodeRow` indices can
    /// never drift between query sites.
    private static let selectColumns = """
        id, project_id, title, source_path, transcript_path,
        engine, duration_ms, status, error_reason,
        created_at, completed_at, kind, origin
        """

    /// Reads a single row by id.
    public func fetch(id: UUID) async throws -> FileRecord? {
        let sql = "SELECT \(Self.selectColumns) FROM files WHERE id = ?"
        return try await database.withStatement(sql: sql) { stmt in
            try stmt.bind(text: id.uuidString, at: 1)
            let res = try stmt.step()
            guard res == .row else { return nil }
            return Self.decodeRow(stmt)
        }
    }

    /// Returns rows in a given status, ordered by created_at ascending.
    public func list(status: FileBatchStatus) async throws -> [FileRecord] {
        let sql = """
            SELECT \(Self.selectColumns)
              FROM files
             WHERE status = ?
             ORDER BY created_at ASC
            """
        return try await database.withStatement(sql: sql) { stmt in
            try stmt.bind(text: status.rawValue, at: 1)
            var out: [FileRecord] = []
            while try stmt.step() == .row {
                if let rec = Self.decodeRow(stmt) { out.append(rec) }
            }
            return out
        }
    }

    /// Lists rows whose `origin` is in `origins` (any status), most-recent first.
    ///
    /// Optionally narrows to one project (`projectID` non-nil) — the driver for
    /// the per-project Files / Voice Memos category lists; pass `nil` for the
    /// global "All files" / "All voice memos" surfaces. `origins` empty → `[]`.
    public func list(
        origins: Set<FileBatchJob.Origin>,
        projectID: String? = nil,
        limit: Int = 500
    ) async throws -> [FileRecord] {
        guard !origins.isEmpty else { return [] }
        let (placeholders, originValues) = SqlInClause.build(origins)
        var sql = "SELECT \(Self.selectColumns) FROM files WHERE origin IN (\(placeholders))"
        if projectID != nil { sql += " AND project_id = ?" }
        sql += " ORDER BY created_at DESC LIMIT ?"
        return try await database.withStatement(sql: sql) { stmt in
            var idx: Int32 = 1
            for value in originValues {
                try stmt.bind(text: value, at: idx)
                idx += 1
            }
            if let projectID {
                try stmt.bind(text: projectID, at: idx)
                idx += 1
            }
            try stmt.bind(int64: Int64(limit), at: idx)
            var out: [FileRecord] = []
            while try stmt.step() == .row {
                if let rec = Self.decodeRow(stmt) { out.append(rec) }
            }
            return out
        }
    }

    /// Of the given source paths, returns the subset that already has a `files`
    /// row (any status).
    ///
    /// Lets the watched-folder / Voice-Memo-sync importer skip
    /// files it already ingested — so a rescan on relaunch never re-imports the
    /// same recording. Empty input → empty result.
    public func sourcePathsPresent(_ paths: [String]) async throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let placeholders = paths.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT source_path FROM files WHERE source_path IN (\(placeholders))"
        return try await database.withStatement(sql: sql) { stmt in
            var idx: Int32 = 1
            for path in paths {
                try stmt.bind(text: path, at: idx)
                idx += 1
            }
            var out: Set<String> = []
            while try stmt.step() == .row {
                if let s = stmt.columnText(at: 0) { out.insert(s) }
            }
            return out
        }
    }

    /// Permanently deletes a file row (the UI "Delete" action).
    ///
    /// The on-disk
    /// transcript/source files are left untouched — the caller decides whether
    /// to remove those.
    public func delete(id: UUID) async throws {
        try await database.withStatement(sql: "DELETE FROM files WHERE id = ?") { stmt in
            try stmt.bind(text: id.uuidString, at: 1)
            _ = try stmt.step()
        }
    }

    private static func decodeRow(_ stmt: SqliteStatement) -> FileRecord? {
        guard let id = stmt.columnText(at: 0),
            let sourcePath = stmt.columnText(at: 3),
            let engine = stmt.columnText(at: 5),
            let statusRaw = stmt.columnText(at: 7),
            let status = FileBatchStatus(rawValue: statusRaw)
        else { return nil }
        let createdAtRaw = stmt.columnInt64(at: 9)
        let completedAtRaw = stmt.columnOptionalInt64(at: 10)
        let kind = stmt.columnText(at: 11).flatMap(FileBatchJob.Kind.init(rawValue:)) ?? .audio
        let origin = stmt.columnText(at: 12).flatMap(FileBatchJob.Origin.init(rawValue:)) ?? .dragDrop
        return FileRecord(
            id: id,
            projectID: stmt.columnText(at: 1),
            title: stmt.columnText(at: 2),
            sourcePath: sourcePath,
            transcriptPath: stmt.columnText(at: 4),
            engine: engine,
            durationMs: stmt.columnOptionalInt64(at: 6),
            status: status,
            errorReason: stmt.columnText(at: 8),
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtRaw)),
            completedAt: completedAtRaw.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            kind: kind,
            origin: origin
        )
    }

    private static func defaultTitle(for job: FileBatchJob) -> String {
        let name = job.sourceURL.deletingPathExtension().lastPathComponent
        if name.isEmpty { return "Untitled file" }
        return name
    }
}
