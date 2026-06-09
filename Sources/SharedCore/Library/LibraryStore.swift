import Foundation
import os

public actor LibraryStore {

    private let db: SqliteDatabase
    private let vectorSearch: VectorSearch
    private let log = Loggers.library

    public init(db: SqliteDatabase, vectorSearch: VectorSearch) {
        self.db = db
        self.vectorSearch = vectorSearch
    }

    public func listMeetings(
        project: String?, filter: LibraryFilter, sort: LibrarySort
    ) async throws -> [LibraryItem] {
        try await listItemsTitled(
            table: "meetings", titleExpression: "title", timeColumn: "started_at",
            source: .meeting, project: project, filter: filter, sort: sort
        )
    }

    public func listDictations(
        project: String?, filter: LibraryFilter, sort: LibrarySort
    ) async throws -> [LibraryItem] {
        try await listItemsTitled(
            table: "dictations",
            titleExpression:
                "COALESCE(NULLIF(SUBSTR(COALESCE(cleaned_text, raw_text, ''), 1, 80), ''), 'Untitled dictation')",
            timeColumn: "started_at",
            source: .dictation, project: project, filter: filter, sort: sort
        )
    }

    public func listFiles(
        project: String?, filter: LibraryFilter, sort: LibrarySort
    ) async throws -> [LibraryItem] {
        try await listItemsTitled(
            table: "files",
            titleExpression: "COALESCE(title, source_path, 'Untitled file')",
            timeColumn: "created_at",
            source: .file, project: project, filter: filter, sort: sort
        )
    }

    public func listVoiceMemos(
        project: String?, filter: LibraryFilter, sort: LibrarySort
    ) async throws -> [LibraryItem] {
        try await listItemsTitled(
            table: "voice_memos",
            titleExpression: "COALESCE(title, 'Voice memo')",
            timeColumn: "started_at",
            source: .voiceMemo, project: project, filter: filter, sort: sort
        )
    }

    public func recentItems(limit: Int) async throws -> [LibraryItem] {
        // Each UNION branch is pre-sorted and pre-limited (the per-table
        // started_at indexes make that a cheap top-N) so the outer sort works on
        // at most 4×limit rows instead of every row of every table.
        let sql = """
            SELECT id, project_id, title, started_at, src FROM (
              SELECT * FROM (
                SELECT id, project_id, title, started_at, 'meeting' AS src FROM meetings
                ORDER BY started_at DESC LIMIT ?)
              UNION ALL
              SELECT * FROM (
                SELECT id, project_id,
                       COALESCE(NULLIF(SUBSTR(COALESCE(cleaned_text, raw_text, ''), 1, 80), ''), 'Untitled dictation') AS title,
                       started_at, 'dictation' AS src FROM dictations
                ORDER BY started_at DESC LIMIT ?)
              UNION ALL
              SELECT * FROM (
                SELECT id, project_id,
                       COALESCE(title, source_path, 'Untitled file') AS title,
                       created_at AS started_at, 'file' AS src FROM files
                ORDER BY started_at DESC LIMIT ?)
              UNION ALL
              SELECT * FROM (
                SELECT id, project_id,
                       COALESCE(title, 'Voice memo') AS title,
                       started_at, 'voiceMemo' AS src FROM voice_memos
                ORDER BY started_at DESC LIMIT ?)
            ) ORDER BY started_at DESC LIMIT ?
            """
        let raw = try await db.withStatement(sql: sql) { stmt -> [(String, String?, String, Int64, String)] in
            for index in Int32(1)...5 {
                try stmt.bind(int: limit, at: index)
            }
            var rows: [(String, String?, String, Int64, String)] = []
            while try stmt.step() == .row {
                guard let id = stmt.columnText(at: 0),
                    let title = stmt.columnText(at: 2),
                    let srcStr = stmt.columnText(at: 4)
                else { continue }
                rows.append((id, stmt.columnText(at: 1), title, stmt.columnInt64(at: 3), srcStr))
            }
            return rows
        }
        return raw.compactMap { tuple in
            guard let src = LibraryItem.Source(rawValue: tuple.4) else { return nil }
            return LibraryItem(
                id: tuple.0, source: src, projectId: tuple.1,
                title: tuple.2, startedAt: Date(timeIntervalSince1970: TimeInterval(tuple.3))
            )
        }
    }

    /// FTS5 keyword search over meeting transcripts + scratchpad notes, ranked by
    /// bm25 relevance and scoped by project / recency / source.
    ///
    /// Returns granular
    /// per-utterance (transcript) and per-meeting (notes) hits carrying enough
    /// provenance to deep-link to `meeting @ timestamp`; the caller groups for
    /// display.
    public func searchKeyword(
        query: String, scope: LibrarySearchScope, limit: Int = 50
    ) async throws -> [KeywordHit] {
        guard let match = Self.ftsMatchQuery(from: query) else { return [] }
        var hits: [KeywordHit] = []

        let wantsTranscript =
            scope.sources.isEmpty
            || scope.sources.contains(.transcript) || scope.sources.contains(.meeting)
        if wantsTranscript {
            let raw = try await ftsKeywordHits(
                sql: """
                    SELECT t.meeting_id, t.speaker, t.text, t.timestamp, m.title, m.project_id, m.started_at
                      FROM transcript_fts AS t
                      JOIN meetings AS m ON m.id = t.meeting_id
                     WHERE transcript_fts MATCH ? ORDER BY rank LIMIT ?
                    """,
                textBinds: [match], limit: limit
            ) { stmt in
                guard let meetingId = stmt.columnText(at: 0), let text = stmt.columnText(at: 2) else { return nil }
                let timestamp = stmt.columnDouble(at: 3)
                return KeywordHit(
                    id: "transcript:\(meetingId):\(timestamp)",
                    source: .transcript, itemId: meetingId, projectId: stmt.columnText(at: 5),
                    title: stmt.columnText(at: 4) ?? "Untitled meeting", snippet: text, timestamp: timestamp,
                    speaker: SpeakerLabel.display(forRawSpeaker: stmt.columnTextRequired(at: 1)),
                    startedAt: Self.epochToDate(stmt.columnOptionalInt64(at: 6))
                )
            }
            hits += raw.filter { scopePasses(projectId: $0.projectId, startedAt: $0.startedAt, scope: scope) }
        }

        let wantsNotes =
            scope.sources.isEmpty
            || scope.sources.contains(.notes) || scope.sources.contains(.meeting)
        if wantsNotes {
            let raw = try await ftsKeywordHits(
                sql: """
                    SELECT n.meeting_id, n.text, m.title, m.project_id, m.started_at
                      FROM notes_fts AS n
                      JOIN meetings AS m ON m.id = n.meeting_id
                     WHERE notes_fts MATCH ? ORDER BY rank LIMIT ?
                    """,
                textBinds: [match], limit: limit
            ) { stmt in
                guard let meetingId = stmt.columnText(at: 0), let text = stmt.columnText(at: 1) else { return nil }
                return KeywordHit(
                    id: "notes:\(meetingId)", source: .notes, itemId: meetingId, projectId: stmt.columnText(at: 3),
                    title: stmt.columnText(at: 2) ?? "Untitled meeting", snippet: text, timestamp: nil,
                    speaker: nil, startedAt: Self.epochToDate(stmt.columnOptionalInt64(at: 4))
                )
            }
            hits += raw.filter { scopePasses(projectId: $0.projectId, startedAt: $0.startedAt, scope: scope) }
        }

        // Whole-item sources (dictation / file / voice memo) live in `entry_fts`.
        // Unlike transcript/notes, they're searched ONLY when explicitly requested
        // in `scope.sources` — never via the empty-set default — so cross-meeting
        // Q&A (which passes an empty source set) keeps citing meetings only.
        for source in [LibraryItem.Source.dictation, .file, .voiceMemo]
        where scope.sources.contains(source) {
            let raw = try await entryKeywordHits(match: match, source: source, limit: limit)
            hits += raw.filter { scopePasses(projectId: $0.projectId, startedAt: $0.startedAt, scope: scope) }
        }

        return hits
    }

    /// FTS5 keyword search over one whole-item source in `entry_fts`.
    ///
    /// Returns a
    /// focused `snippet()` excerpt (the view re-highlights the query terms) and the
    /// stored provenance, ranked by bm25.
    private func entryKeywordHits(
        match: String, source: LibraryItem.Source, limit: Int
    ) async throws -> [KeywordHit] {
        try await ftsKeywordHits(
            sql: """
                SELECT item_id, project_id, title, started_at, snippet(entry_fts, 6, '', '', '…', 18)
                  FROM entry_fts
                 WHERE entry_fts MATCH ? AND source = ? ORDER BY rank LIMIT ?
                """,
            textBinds: [match, source.rawValue], limit: limit
        ) { stmt in
            guard let itemId = stmt.columnText(at: 0) else { return nil }
            return KeywordHit(
                id: "\(source.rawValue):\(itemId)", source: source, itemId: itemId,
                projectId: stmt.columnText(at: 1),
                title: stmt.columnText(at: 2) ?? Self.defaultEntryTitle(source),
                snippet: stmt.columnText(at: 4) ?? "",
                timestamp: nil, speaker: nil,
                startedAt: Self.epochToDate(stmt.columnOptionalInt64(at: 3))
            )
        }
    }

    private static func defaultEntryTitle(_ source: LibraryItem.Source) -> String {
        switch source {
        case .dictation: return "Dictation"
        case .file: return "File"
        case .voiceMemo: return "Voice memo"
        default: return "Item"
        }
    }

    /// Runs an FTS5 `… ? … LIMIT ?` query and collects the rows `decode`
    /// returns (nil drops a row — used for the in-Swift scope filter).
    ///
    /// `textBinds` are bound in order from index 1 (the MATCH expression first,
    /// plus any extra bound predicates like `entry_fts.source`); `limit` is
    /// always the final placeholder. Owns the bind/step/loop boilerplate shared
    /// by the transcript / notes / entry arms.
    private func ftsKeywordHits(
        sql: String, textBinds: [String], limit: Int,
        decode: @Sendable (SqliteStatement) -> KeywordHit?
    ) async throws -> [KeywordHit] {
        try await db.withStatement(sql: sql) { stmt in
            for (offset, value) in textBinds.enumerated() {
                try stmt.bind(text: value, at: Int32(offset + 1))
            }
            try stmt.bind(int: limit, at: Int32(textBinds.count + 1))
            var hits: [KeywordHit] = []
            while try stmt.step() == .row {
                if let hit = decode(stmt) { hits.append(hit) }
            }
            return hits
        }
    }

    private static func epochToDate(_ epoch: Int64?) -> Date? {
        epoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Builds a safe FTS5 MATCH expression from free-form user input: lowercases,
    /// splits on non-alphanumerics, quotes each token (so the raw text can never
    /// inject FTS5 operators and crash the query), and space-joins them for
    /// implicit AND.
    ///
    /// Returns nil when the query has no searchable tokens.
    static func ftsMatchQuery(from raw: String) -> String? {
        let terms = raw.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"" }.joined(separator: " ")
    }

    public func searchSemantic(
        queryVector: [Float], scope: LibrarySearchScope, top: Int
    ) async throws -> [SemanticHit] {
        let raw = try await vectorSearch.topK(query: queryVector, k: top)
        return raw.map { SemanticHit(id: "playbook:\($0.chunk.id)", chunk: $0.chunk, score: $0.score) }
    }

    private func scopePasses(projectId: String?, startedAt: Date?, scope: LibrarySearchScope) -> Bool {
        if let projectIds = scope.projectIds, !projectIds.isEmpty {
            guard let projectId, projectIds.contains(projectId) else { return false }
        }
        if let cutoff = scope.cutoffDate {
            guard let startedAt, startedAt >= cutoff else { return false }
        }
        return true
    }

    private func listItemsTitled(
        table: String, titleExpression: String, timeColumn: String,
        source: LibraryItem.Source, project: String?, filter: LibraryFilter, sort: LibrarySort
    ) async throws -> [LibraryItem] {
        struct BoundParam: Sendable {
            enum Kind: Sendable {
                case text(String)
                case int64(Int64)
            }
            let kind: Kind
        }
        var conditions: [String] = []
        var params: [BoundParam] = []
        if let project {
            conditions.append("project_id = ?")
            params.append(BoundParam(kind: .text(project)))
        }
        if let after = filter.startedOnOrAfter {
            conditions.append("\(timeColumn) >= ?")
            params.append(BoundParam(kind: .int64(Int64(after.timeIntervalSince1970))))
        }
        if let before = filter.startedOnOrBefore {
            conditions.append("\(timeColumn) <= ?")
            params.append(BoundParam(kind: .int64(Int64(before.timeIntervalSince1970))))
        }
        if let query = filter.query, !query.isEmpty {
            conditions.append("LOWER(\(titleExpression)) LIKE ?")
            params.append(BoundParam(kind: .text("%\(query.lowercased())%")))
        }
        if let templateId = filter.templateId, table == "meetings" {
            conditions.append("template_id = ?")
            params.append(BoundParam(kind: .text(templateId)))
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let orderClause = Self.orderClause(for: sort, timeColumn: timeColumn, titleExpression: titleExpression)
        let sql = """
            SELECT id, project_id, \(titleExpression) AS title_synth, \(timeColumn) AS started_at_synth
              FROM \(table) \(whereClause) \(orderClause)
            """
        let raw = try await db.withStatement(sql: sql) { stmt -> [(String, String?, String, Int64)] in
            for (offset, param) in params.enumerated() {
                let idx = Int32(offset + 1)
                switch param.kind {
                case .text(let s): try stmt.bind(text: s, at: idx)
                case .int64(let v): try stmt.bind(int64: v, at: idx)
                }
            }
            var rows: [(String, String?, String, Int64)] = []
            while try stmt.step() == .row {
                guard let id = stmt.columnText(at: 0),
                    let title = stmt.columnText(at: 2)
                else { continue }
                rows.append((id, stmt.columnText(at: 1), title, stmt.columnInt64(at: 3)))
            }
            return rows
        }
        return raw.map { tuple in
            LibraryItem(
                id: tuple.0, source: source, projectId: tuple.1,
                title: tuple.2, startedAt: Date(timeIntervalSince1970: TimeInterval(tuple.3))
            )
        }
    }

    private static func orderClause(
        for sort: LibrarySort, timeColumn: String, titleExpression: String
    ) -> String {
        switch sort {
        case .startedAtAscending: return "ORDER BY \(timeColumn) ASC"
        case .startedAtDescending: return "ORDER BY \(timeColumn) DESC"
        case .titleAscending: return "ORDER BY \(titleExpression) ASC"
        case .titleDescending: return "ORDER BY \(titleExpression) DESC"
        }
    }
}
