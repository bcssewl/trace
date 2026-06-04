import Foundation

public struct ProjectRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let indicatorColor: String
    public let defaultTemplateId: UUID?
    public let coachConfigJson: String
    /// Per-project model/ASR route overrides + vocabulary + calendar matchers,
    /// stored as JSON (schema v30).
    ///
    /// Decode via `overrides`.
    public let overridesJson: String
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(
        id: UUID, name: String, indicatorColor: String,
        defaultTemplateId: UUID?, coachConfigJson: String,
        overridesJson: String = "{}",
        createdAt: Int64, updatedAt: Int64
    ) {
        self.id = id
        self.name = name
        self.indicatorColor = indicatorColor
        self.defaultTemplateId = defaultTemplateId
        self.coachConfigJson = coachConfigJson
        self.overridesJson = overridesJson
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The decoded per-project overrides (`.empty` if unset/malformed).
    public var overrides: ProjectOverrides { ProjectOverrides.decode(json: overridesJson) }
}

public actor ProjectStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) {
        self.database = database
    }

    public func create(name: String, indicatorColor: String = "#ff3300") async throws -> ProjectRecord {
        let id = UUID()
        let now = Int64(Date().timeIntervalSince1970)
        try await database.withStatement(
            sql: """
                INSERT INTO projects (id, name, indicator_color, coach_config, created_at, updated_at)
                VALUES (?, ?, ?, '{}', ?, ?)
                """
        ) { stmt in
            try stmt.bind(text: id.uuidString, at: 1)
            try stmt.bind(text: name, at: 2)
            try stmt.bind(text: indicatorColor, at: 3)
            try stmt.bind(int64: now, at: 4)
            try stmt.bind(int64: now, at: 5)
            _ = try stmt.step()
        }
        return ProjectRecord(
            id: id, name: name, indicatorColor: indicatorColor,
            defaultTemplateId: nil, coachConfigJson: "{}",
            createdAt: now, updatedAt: now
        )
    }

    /// Column list shared by every `SELECT` so the `decodeRow` indices can't
    /// drift between `list` and `fetch`.
    private static let selectColumns =
        "id, name, indicator_color, default_template_id, coach_config, created_at, updated_at, overrides_json"

    public func list() async throws -> [ProjectRecord] {
        try await database.withStatement(
            sql: "SELECT \(Self.selectColumns) FROM projects ORDER BY name ASC"
        ) { stmt in
            var out: [ProjectRecord] = []
            while try stmt.step() == .row {
                if let rec = Self.decodeRow(stmt) { out.append(rec) }
            }
            return out
        }
    }

    /// Reads a single project by id.
    public func fetch(id: UUID) async throws -> ProjectRecord? {
        try await database.withStatement(
            sql: "SELECT \(Self.selectColumns) FROM projects WHERE id = ?"
        ) { stmt in
            try stmt.bind(text: id.uuidString, at: 1)
            guard try stmt.step() == .row else { return nil }
            return Self.decodeRow(stmt)
        }
    }

    private static func decodeRow(_ stmt: SqliteStatement) -> ProjectRecord? {
        guard let idText = stmt.columnText(at: 0), let id = UUID(uuidString: idText),
            let name = stmt.columnText(at: 1),
            let color = stmt.columnText(at: 2)
        else { return nil }
        let templateId = stmt.columnText(at: 3).flatMap(UUID.init(uuidString:))
        let coach = stmt.columnText(at: 4) ?? "{}"
        let createdAt = stmt.columnInt64(at: 5)
        let updatedAt = stmt.columnInt64(at: 6)
        let overrides = stmt.columnText(at: 7) ?? "{}"
        return ProjectRecord(
            id: id, name: name, indicatorColor: color,
            defaultTemplateId: templateId, coachConfigJson: coach,
            overridesJson: overrides, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    public func delete(id: UUID) async throws {
        try await database.withStatement(sql: "DELETE FROM projects WHERE id = ?") { stmt in
            try stmt.bind(text: id.uuidString, at: 1)
            _ = try stmt.step()
        }
    }

    /// Rename a project. `projects.name` is UNIQUE, so renaming to an existing
    /// name throws a constraint error the caller can surface.
    public func rename(id: UUID, name: String) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        try await database.withStatement(
            sql: "UPDATE projects SET name = ?, updated_at = ? WHERE id = ?"
        ) { stmt in
            try stmt.bind(text: name, at: 1)
            try stmt.bind(int64: now, at: 2)
            try stmt.bind(text: id.uuidString, at: 3)
            _ = try stmt.step()
        }
    }

    /// Full per-project settings update (the overrides editor's "Save").
    ///
    /// Writes
    /// name, color, default template, coach config, and the override blob in one
    /// statement.
    public func update(
        id: UUID,
        name: String,
        indicatorColor: String,
        defaultTemplateId: UUID?,
        coachConfigJson: String,
        overrides: ProjectOverrides
    ) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        try await database.withStatement(
            sql: """
                UPDATE projects
                   SET name = ?, indicator_color = ?, default_template_id = ?,
                       coach_config = ?, overrides_json = ?, updated_at = ?
                 WHERE id = ?
                """
        ) { stmt in
            try stmt.bind(text: name, at: 1)
            try stmt.bind(text: indicatorColor, at: 2)
            try stmt.bind(optionalText: defaultTemplateId?.uuidString, at: 3)
            try stmt.bind(text: coachConfigJson, at: 4)
            try stmt.bind(text: overrides.encodedJSON(), at: 5)
            try stmt.bind(int64: now, at: 6)
            try stmt.bind(text: id.uuidString, at: 7)
            _ = try stmt.step()
        }
    }

    /// Targeted update of just the override blob (used by tests + any
    /// override-only edit path).
    public func setOverrides(id: UUID, _ overrides: ProjectOverrides) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        try await database.withStatement(
            sql: "UPDATE projects SET overrides_json = ?, updated_at = ? WHERE id = ?"
        ) { stmt in
            try stmt.bind(text: overrides.encodedJSON(), at: 1)
            try stmt.bind(int64: now, at: 2)
            try stmt.bind(text: id.uuidString, at: 3)
            _ = try stmt.step()
        }
    }

    public func childCounts(projectId: UUID) async throws -> ProjectChildCounts {
        let id = projectId.uuidString
        let meetings = try await countByProject(table: "meetings", id: id)
        let dictations = try await countByProject(table: "dictations", id: id)
        // Voice memos and files are BOTH rows in the `files` table (the batch
        // pipeline writes every transcription output there); they're split by
        // `origin`. The legacy `voice_memos` table has no writers (BAS-22).
        let memos = try await countFilesByOrigin(id: id, origins: FileRecord.voiceMemoOrigins)
        let files = try await countFilesByOrigin(id: id, origins: FileRecord.fileOrigins)
        return ProjectChildCounts(meetings: meetings, dictations: dictations, voiceMemos: memos, files: files)
    }

    /// Child counts for EVERY project in a fixed 3 queries (vs `childCounts`'s 4
    /// per project) — the sidebar driver, which would otherwise issue N×4 COUNTs
    /// and re-run on every meeting start/stop. One `GROUP BY project_id` per
    /// table; files split by origin bucket.
    public func allChildCounts() async throws -> [UUID: ProjectChildCounts] {
        let meetings = try await groupedCounts(table: "meetings")
        let dictations = try await groupedCounts(table: "dictations")
        var memoCounts: [String: Int] = [:]
        var fileCounts: [String: Int] = [:]
        try await database.withStatement(
            sql:
                "SELECT project_id, origin, COUNT(*) FROM files WHERE project_id IS NOT NULL GROUP BY project_id, origin"
        ) { stmt in
            while try stmt.step() == .row {
                guard let pid = stmt.columnText(at: 0), let originRaw = stmt.columnText(at: 1),
                    let origin = FileBatchJob.Origin(rawValue: originRaw)
                else { continue }
                let count = stmt.columnInt(at: 2)
                if FileRecord.voiceMemoOrigins.contains(origin) {
                    memoCounts[pid, default: 0] += count
                } else if FileRecord.fileOrigins.contains(origin) {
                    fileCounts[pid, default: 0] += count
                }
            }
        }
        let ids = Set(meetings.keys).union(dictations.keys).union(memoCounts.keys).union(fileCounts.keys)
        var out: [UUID: ProjectChildCounts] = [:]
        for idStr in ids {
            guard let id = UUID(uuidString: idStr) else { continue }
            out[id] = ProjectChildCounts(
                meetings: meetings[idStr] ?? 0, dictations: dictations[idStr] ?? 0,
                voiceMemos: memoCounts[idStr] ?? 0, files: fileCounts[idStr] ?? 0
            )
        }
        return out
    }

    private func groupedCounts(table: String) async throws -> [String: Int] {
        try await database.withStatement(
            sql: "SELECT project_id, COUNT(*) FROM \(table) WHERE project_id IS NOT NULL GROUP BY project_id"
        ) { stmt in
            var out: [String: Int] = [:]
            while try stmt.step() == .row {
                if let pid = stmt.columnText(at: 0) { out[pid] = stmt.columnInt(at: 1) }
            }
            return out
        }
    }

    private func countByProject(table: String, id: String) async throws -> Int {
        try await database.withStatement(sql: "SELECT COUNT(*) FROM \(table) WHERE project_id = ?") { stmt in
            try stmt.bind(text: id, at: 1)
            let res = try stmt.step()
            return res == .row ? stmt.columnInt(at: 0) : 0
        }
    }

    private func countFilesByOrigin(id: String, origins: Set<FileBatchJob.Origin>) async throws -> Int {
        guard !origins.isEmpty else { return 0 }
        let (placeholders, originValues) = SqlInClause.build(origins)
        let sql = "SELECT COUNT(*) FROM files WHERE project_id = ? AND origin IN (\(placeholders))"
        return try await database.withStatement(sql: sql) { stmt in
            try stmt.bind(text: id, at: 1)
            var idx: Int32 = 2
            for value in originValues {
                try stmt.bind(text: value, at: idx)
                idx += 1
            }
            let res = try stmt.step()
            return res == .row ? stmt.columnInt(at: 0) : 0
        }
    }

    /// Count of meetings not filed into any project — drives the "Inbox" badge.
    public func inboxMeetingCount() async throws -> Int {
        try await database.withStatement(sql: "SELECT COUNT(*) FROM meetings WHERE project_id IS NULL") { stmt in
            let res = try stmt.step()
            return res == .row ? stmt.columnInt(at: 0) : 0
        }
    }

    /// Total number of playbook folder records across all projects.
    public func playbookCount() async throws -> Int {
        try await database.withStatement(sql: "SELECT COUNT(*) FROM playbooks") { stmt in
            let res = try stmt.step()
            return res == .row ? stmt.columnInt(at: 0) : 0
        }
    }
}

public struct ProjectChildCounts: Sendable, Hashable {
    public let meetings: Int
    public let dictations: Int
    public let voiceMemos: Int
    public let files: Int

    public init(meetings: Int, dictations: Int, voiceMemos: Int, files: Int) {
        self.meetings = meetings
        self.dictations = dictations
        self.voiceMemos = voiceMemos
        self.files = files
    }

    public var total: Int { meetings + dictations + voiceMemos + files }
}
