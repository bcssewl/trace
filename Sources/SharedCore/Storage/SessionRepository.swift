import Foundation

public struct UtteranceEnrichment: Sendable, Codable, Hashable {
    public var fields: [String: String]

    public init(fields: [String: String] = [:]) {
        self.fields = fields
    }
}

public struct PendingUtteranceKey: Sendable, Hashable {
    public let utteranceID: UUID
    public init(utteranceID: UUID = UUID()) {
        self.utteranceID = utteranceID
    }
}

public actor SessionRepository {
    private let database: SqliteDatabase
    private let fts: FtsIndex
    private let markdown: MarkdownStore
    private let enrichmentDelay: Duration

    private var liveWriters: [String: JsonlWriter] = [:]
    private var pending: [PendingUtteranceKey: PendingEntry] = [:]

    private struct PendingEntry {
        var utterance: Utterance
        var enrichment: UtteranceEnrichment
        var sessionId: String
        var task: Task<Void, Never>
    }

    public init(
        database: SqliteDatabase,
        markdown: MarkdownStore,
        enrichmentDelay: Duration = .seconds(5)
    ) {
        self.database = database
        self.fts = FtsIndex(database: database)
        self.markdown = markdown
        self.enrichmentDelay = enrichmentDelay
    }

    public func createSession(_ metadata: SessionMetadata, projectFolderName: String) async throws {
        let layout = try markdown.layout(projectFolderName: projectFolderName, sessionId: metadata.sessionId)
        try layout.createDirectories()
        try markdown.writeSessionJson(metadata, to: layout)

        try await database.withStatement(
            sql: """
                    INSERT INTO meetings (
                        id, project_id, title, started_at, ended_at,
                        template_id, calendar_event_id,
                        auto_categorized_confidence, manual_override, session_dir_path
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
        ) { stmt in
            try stmt.bind(text: metadata.sessionId, at: 1)
            try stmt.bind(optionalText: metadata.projectId, at: 2)
            try stmt.bind(optionalText: metadata.title, at: 3)
            try stmt.bind(int64: Int64(metadata.startedAt.timeIntervalSince1970), at: 4)
            try stmt.bind(optionalInt64: metadata.endedAt.map { Int64($0.timeIntervalSince1970) }, at: 5)
            try stmt.bind(optionalText: metadata.templateId, at: 6)
            try stmt.bind(optionalText: metadata.calendarEventId, at: 7)
            try stmt.bind(optionalDouble: metadata.autoCategorizedConfidence, at: 8)
            try stmt.bind(int: metadata.manualOverride ? 1 : 0, at: 9)
            try stmt.bind(text: layout.sessionDirectory.path, at: 10)
            _ = try stmt.step()
        }

        liveWriters[metadata.sessionId] = JsonlWriter(url: layout.transcriptLiveURL)
        Loggers.storage.info("Created session \(metadata.sessionId, privacy: .public)")
    }

    /// All meetings, most-recent first — backs the "All meetings" library list.
    ///
    /// Reads the `meetings` index table (the `meetings_started` index makes this
    /// ordering cheap). Optionally scoped to one project.
    /// Meetings not filed into any project — the triage Inbox queue. Most-recent
    /// first; assigning a meeting to a project removes it from this list.
    ///
    /// `limit` defaults to unbounded: these are metadata-only rows (a few hundred
    /// bytes each), and the old default of 500 made meetings beyond it silently
    /// vanish from the library. Use ``listMeetingsPage(projectId:inboxOnly:after:limit:)``
    /// for incremental loading.
    public func listInboxMeetings(limit: Int = Int.max) async throws -> [SessionMetadata] {
        let sql = """
            SELECT id, project_id, title, started_at, ended_at, session_dir_path
            FROM meetings WHERE project_id IS NULL ORDER BY started_at DESC LIMIT ?
            """
        return try await database.withStatement(sql: sql) { stmt in
            try stmt.bind(int: limit, at: 1)
            var out: [SessionMetadata] = []
            while try stmt.step() == .row {
                if let meta = Self.decodeMetadataRow(stmt) { out.append(meta) }
            }
            return out
        }
    }

    /// All meetings (optionally one project's), most-recent first.
    ///
    /// `limit`
    /// defaults to unbounded — see ``listInboxMeetings(limit:)`` for why.
    public func listMeetings(projectId: String? = nil, limit: Int = Int.max) async throws -> [SessionMetadata] {
        let base = "SELECT id, project_id, title, started_at, ended_at, session_dir_path FROM meetings"
        let sql =
            projectId == nil
            ? "\(base) ORDER BY started_at DESC LIMIT ?"
            : "\(base) WHERE project_id = ? ORDER BY started_at DESC LIMIT ?"
        return try await database.withStatement(sql: sql) { stmt in
            if let projectId {
                try stmt.bind(text: projectId, at: 1)
                try stmt.bind(int: limit, at: 2)
            } else {
                try stmt.bind(int: limit, at: 1)
            }
            var out: [SessionMetadata] = []
            while try stmt.step() == .row {
                if let meta = Self.decodeMetadataRow(stmt) { out.append(meta) }
            }
            return out
        }
    }

    // MARK: Keyset pagination

    /// Opaque "everything strictly after this row" position for
    /// ``listMeetingsPage(projectId:inboxOnly:after:limit:)``.
    ///
    /// Keyset (started_at, id) rather than OFFSET, so a page boundary stays
    /// stable while rows are inserted or deleted between fetches.
    public struct MeetingPageCursor: Sendable, Hashable {
        public let startedAt: Date
        public let sessionId: String
        public init(startedAt: Date, sessionId: String) {
            self.startedAt = startedAt
            self.sessionId = sessionId
        }
    }

    /// One page of meetings plus the cursor for the next page (nil = no more).
    public struct MeetingPage: Sendable {
        public let items: [SessionMetadata]
        public let nextCursor: MeetingPageCursor?
        public var hasMore: Bool { nextCursor != nil }
        public init(items: [SessionMetadata], nextCursor: MeetingPageCursor?) {
            self.items = items
            self.nextCursor = nextCursor
        }
    }

    /// Paginated meeting list (most-recent first), the incremental-loading
    /// counterpart of ``listMeetings(projectId:limit:)`` /
    /// ``listInboxMeetings(limit:)``.
    ///
    /// Pass `after: page.nextCursor` to fetch
    /// the next page; `inboxOnly` scopes to uncategorised meetings (and ignores
    /// `projectId`).
    public func listMeetingsPage(
        projectId: String? = nil,
        inboxOnly: Bool = false,
        after cursor: MeetingPageCursor? = nil,
        limit: Int = 100
    ) async throws -> MeetingPage {
        var conditions: [String] = []
        if inboxOnly {
            conditions.append("project_id IS NULL")
        } else if projectId != nil {
            conditions.append("project_id = ?")
        }
        if cursor != nil {
            conditions.append("(started_at < ? OR (started_at = ? AND id < ?))")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT id, project_id, title, started_at, ended_at, session_dir_path
              FROM meetings \(whereClause)
             ORDER BY started_at DESC, id DESC LIMIT ?
            """
        let fetchLimit = max(1, limit)
        let rows = try await database.withStatement(sql: sql) { stmt -> [SessionMetadata] in
            var idx: Int32 = 1
            if !inboxOnly, let projectId {
                try stmt.bind(text: projectId, at: idx)
                idx += 1
            }
            if let cursor {
                let epoch = Int64(cursor.startedAt.timeIntervalSince1970)
                try stmt.bind(int64: epoch, at: idx)
                try stmt.bind(int64: epoch, at: idx + 1)
                try stmt.bind(text: cursor.sessionId, at: idx + 2)
                idx += 3
            }
            // Fetch one extra row to learn whether a further page exists.
            try stmt.bind(int: fetchLimit + 1, at: idx)
            var out: [SessionMetadata] = []
            while try stmt.step() == .row {
                if let meta = Self.decodeMetadataRow(stmt) { out.append(meta) }
            }
            return out
        }
        let hasMore = rows.count > fetchLimit
        let items = hasMore ? Array(rows.prefix(fetchLimit)) : rows
        let next = hasMore
            ? items.last.map { MeetingPageCursor(startedAt: $0.startedAt, sessionId: $0.sessionId) }
            : nil
        return MeetingPage(items: items, nextCursor: next)
    }

    /// Decode the shared `id, project_id, title, started_at, ended_at,
    /// session_dir_path` column shape used by every meeting list query.
    private static func decodeMetadataRow(_ stmt: SqliteStatement) -> SessionMetadata? {
        guard let id = stmt.columnText(at: 0), let dir = stmt.columnText(at: 5) else { return nil }
        let endedRaw = stmt.columnInt64(at: 4)
        return SessionMetadata(
            sessionId: id,
            projectId: stmt.columnText(at: 1),
            title: stmt.columnText(at: 2),
            startedAt: Date(timeIntervalSince1970: TimeInterval(stmt.columnInt64(at: 3))),
            endedAt: endedRaw == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(endedRaw)),
            sessionDirPath: dir
        )
    }

    /// Load one finalized meeting's content (notes + summary + transcript) from
    /// its session directory for read-only display.
    ///
    /// Missing files → empty.
    public func loadSavedMeeting(_ metadata: SessionMetadata) -> SavedMeeting {
        let dir = URL(fileURLWithPath: metadata.sessionDirPath)
        let notes = (try? String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
        let summary = try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
        return SavedMeeting(
            metadata: metadata,
            notes: notes,
            summary: summary,
            utterances: Self.loadTranscript(in: dir)
        )
    }

    /// The canonical transcript file for a session directory: the finalized
    /// JSONL when present, else the live stream, else nil.
    ///
    /// Shared with
    /// `StorageReconciler`, which verifies the FTS index against this file.
    static func canonicalTranscriptURL(in dir: URL) -> URL? {
        let finalURL = dir.appendingPathComponent("transcript.final.jsonl")
        if FileManager.default.fileExists(atPath: finalURL.path) { return finalURL }
        let liveURL = dir.appendingPathComponent("transcript.live.jsonl")
        if FileManager.default.fileExists(atPath: liveURL.path) { return liveURL }
        return nil
    }

    /// Parse a session's transcript JSONL (final if present, else the live
    /// stream) into utterances.
    ///
    /// Tolerant: unparseable lines are skipped.
    /// Enriched lines (extra JSON keys) decode fine — unknown keys are ignored.
    static func loadTranscript(in dir: URL) -> [Utterance] {
        guard let url = canonicalTranscriptURL(in: dir),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        var out: [Utterance] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                let utt = try? decoder.decode(Utterance.self, from: data)
            else { continue }
            out.append(utt)
        }
        return out
    }

    public func appendUtteranceImmediate(_ utterance: Utterance, in sessionId: String) async throws {
        try await persistUtterance(utterance, sessionId: sessionId, enrichment: nil)
    }

    @discardableResult
    public func appendUtteranceDeferred(
        _ utterance: Utterance,
        in sessionId: String
    ) -> PendingUtteranceKey {
        let key = PendingUtteranceKey()
        let task = Task { [weak self] in
            try? await Task.sleep(for: self?.enrichmentDelay ?? .seconds(5))
            await self?.flushPendingIfStillPresent(key: key)
        }
        pending[key] = PendingEntry(
            utterance: utterance,
            enrichment: UtteranceEnrichment(),
            sessionId: sessionId,
            task: task
        )
        return key
    }

    public func attachEnrichment(key: PendingUtteranceKey, fields: [String: String]) {
        guard var entry = pending[key] else { return }
        for (k, v) in fields {
            entry.enrichment.fields[k] = v
        }
        pending[key] = entry
    }

    public func flushPendingNow(key: PendingUtteranceKey) async throws {
        guard let entry = pending.removeValue(forKey: key) else { return }
        entry.task.cancel()
        try await persistUtterance(entry.utterance, sessionId: entry.sessionId, enrichment: entry.enrichment)
    }

    private func flushPendingIfStillPresent(key: PendingUtteranceKey) async {
        guard let entry = pending.removeValue(forKey: key) else { return }
        do {
            try await persistUtterance(entry.utterance, sessionId: entry.sessionId, enrichment: entry.enrichment)
        } catch {
            Loggers.storage.error("Deferred utterance flush failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func persistUtterance(
        _ utterance: Utterance, sessionId: String, enrichment: UtteranceEnrichment?
    ) async throws {
        if let writer = liveWriters[sessionId] {
            if let enrichment, !enrichment.fields.isEmpty {
                try await writer.append(EnrichedUtterance(utterance: utterance, enrichment: enrichment))
            } else {
                try await writer.append(utterance)
            }
        }
        try await fts.insertTranscript(
            meetingId: sessionId,
            speaker: utterance.speaker.rawValue,
            text: utterance.text,
            timestamp: utterance.t
        )
    }

    public func updateMeetingTitle(_ title: String, sessionId: String) async throws {
        try await database.withStatement(
            sql: "UPDATE meetings SET title = ? WHERE id = ?"
        ) { stmt in
            try stmt.bind(text: title, at: 1)
            try stmt.bind(text: sessionId, at: 2)
            _ = try stmt.step()
        }
        if let layout = try? await layoutFor(sessionId: sessionId) {
            var meta = try markdown.readSessionJson(at: layout)
            meta = SessionMetadata(
                sessionId: meta.sessionId,
                projectId: meta.projectId,
                title: title,
                startedAt: meta.startedAt,
                endedAt: meta.endedAt,
                templateId: meta.templateId,
                calendarEventId: meta.calendarEventId,
                autoCategorizedConfidence: meta.autoCategorizedConfidence,
                manualOverride: meta.manualOverride,
                sessionDirPath: meta.sessionDirPath
            )
            try markdown.writeSessionJson(meta, to: layout)
        }
    }

    /// File a meeting into a project (or Inbox when `projectId` is nil).
    ///
    /// Sets the
    /// sticky `manual_override` flag when the user chose it by hand, so the
    /// auto-categorizer never overrides a manual decision (§8.3). Keeps the
    /// on-disk session.json in sync (markdown is the source of truth).
    public func assignProject(
        sessionId: String, projectId: String?, manualOverride: Bool, confidence: Double? = nil
    ) async throws {
        try await database.withStatement(
            sql: "UPDATE meetings SET project_id = ?, manual_override = ?, auto_categorized_confidence = ? WHERE id = ?"
        ) { stmt in
            try stmt.bind(optionalText: projectId, at: 1)
            try stmt.bind(int: manualOverride ? 1 : 0, at: 2)
            try stmt.bind(optionalDouble: confidence, at: 3)
            try stmt.bind(text: sessionId, at: 4)
            _ = try stmt.step()
        }
        if let layout = try? await layoutFor(sessionId: sessionId) {
            let meta = try markdown.readSessionJson(at: layout)
            let updated = SessionMetadata(
                sessionId: meta.sessionId,
                projectId: projectId,
                title: meta.title,
                startedAt: meta.startedAt,
                endedAt: meta.endedAt,
                templateId: meta.templateId,
                calendarEventId: meta.calendarEventId,
                autoCategorizedConfidence: confidence ?? meta.autoCategorizedConfidence,
                manualOverride: manualOverride,
                sessionDirPath: meta.sessionDirPath
            )
            try markdown.writeSessionJson(updated, to: layout)
        }
    }

    public func writeNotes(_ markdownText: String, sessionId: String) async throws {
        let layout = try await layoutFor(sessionId: sessionId)
        try markdown.writeNotes(markdownText, to: layout)
        try await fts.upsertNotes(meetingId: sessionId, text: markdownText)
    }

    /// Permanently delete a meeting: its session directory on disk plus every
    /// database trace — the `meetings` row, transcript/notes FTS rows, vector
    /// index rows (`kb_chunks` / `kb_embeddings`, which used to be left behind
    /// and ghosted in semantic search), and its index-state bookkeeping.
    ///
    /// All
    /// database rows go in one transaction so a crash mid-delete can't leave a
    /// half-deleted meeting. Irreversible.
    public func deleteMeeting(sessionId: String) async throws {
        // Remove the on-disk content FIRST and throw on failure: deleting the
        // DB rows while the audio/transcript files silently survive would tell
        // the user a (possibly sensitive) meeting is gone when it isn't. A
        // failed file removal leaves the meeting fully intact for a retry.
        if let path = try? await sessionDirPath(sessionId: sessionId),
            FileManager.default.fileExists(atPath: path)
        {
            try FileManager.default.removeItem(atPath: path)
        }
        try await database.transaction {
            try await fts.deleteTranscript(meetingId: sessionId)
            try await fts.deleteNotes(meetingId: sessionId)
            let cleanupSQL = [
                "DELETE FROM kb_embeddings WHERE chunk_id IN (SELECT id FROM kb_chunks WHERE meeting_id = ?)",
                "DELETE FROM kb_chunks WHERE meeting_id = ?",
                "DELETE FROM meeting_index_state WHERE meeting_id = ?",
                "DELETE FROM fts_reconcile_state WHERE meeting_id = ?",
                "DELETE FROM meetings WHERE id = ?",
            ]
            for sql in cleanupSQL {
                try await database.withStatement(sql: sql) { stmt in
                    try stmt.bind(text: sessionId, at: 1)
                    _ = try stmt.step()
                }
            }
        }
        Loggers.storage.info("Deleted session \(sessionId, privacy: .public)")
    }

    public func finalizeSession(sessionId: String, endedAt: Date = Date()) async throws {
        for (key, entry) in pending where entry.sessionId == sessionId {
            try await flushPendingNow(key: key)
        }
        if let writer = liveWriters.removeValue(forKey: sessionId) {
            try await writer.close()
        }
        try await database.withStatement(
            sql: "UPDATE meetings SET ended_at = ? WHERE id = ?"
        ) { stmt in
            try stmt.bind(int64: Int64(endedAt.timeIntervalSince1970), at: 1)
            try stmt.bind(text: sessionId, at: 2)
            _ = try stmt.step()
        }
        if let layout = try? await layoutFor(sessionId: sessionId) {
            var meta = try markdown.readSessionJson(at: layout)
            meta.endedAt = endedAt
            try markdown.writeSessionJson(meta, to: layout)
        }
        Loggers.storage.info("Finalized session \(sessionId, privacy: .public)")
    }

    public func pendingCount() -> Int {
        pending.count
    }

    private func layoutFor(sessionId: String) async throws -> SessionLayout {
        let path = try await sessionDirPath(sessionId: sessionId)
        let pathURL = URL(fileURLWithPath: path)
        let projectURL = pathURL.deletingLastPathComponent()
        let rootURL = projectURL.deletingLastPathComponent()
        return SessionLayout(
            root: rootURL,
            projectFolderName: projectURL.lastPathComponent,
            sessionId: sessionId
        )
    }

    private func sessionDirPath(sessionId: String) async throws -> String {
        let path: String? = try await database.withStatement(
            sql: "SELECT session_dir_path FROM meetings WHERE id = ?"
        ) { stmt -> String? in
            try stmt.bind(text: sessionId, at: 1)
            let res = try stmt.step()
            guard res == .row else { return nil }
            return stmt.columnText(at: 0)
        }
        guard let path else {
            throw TraceError.storageFailed(reason: "session \(sessionId) not found")
        }
        return path
    }
}

struct EnrichedUtterance: Encodable {
    let utterance: Utterance
    let enrichment: UtteranceEnrichment

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(utterance.t, forKey: .init(stringValue: "t")!)
        try container.encode(utterance.speaker.rawValue, forKey: .init(stringValue: "speaker")!)
        try container.encode(utterance.text, forKey: .init(stringValue: "text")!)
        try container.encode(utterance.conf, forKey: .init(stringValue: "conf")!)
        if let asr = utterance.asr {
            try container.encode(asr, forKey: .init(stringValue: "asr")!)
        }
        if let diar = utterance.diar {
            try container.encode(diar, forKey: .init(stringValue: "diar")!)
        }
        if let cleaned = utterance.cleaned {
            try container.encode(cleaned, forKey: .init(stringValue: "cleaned")!)
        }
        for (k, v) in enrichment.fields {
            try container.encode(v, forKey: .init(stringValue: k)!)
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) {
            self.stringValue = stringValue
        }
        init?(intValue: Int) { nil }
    }
}
