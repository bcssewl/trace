import CryptoKit
import Foundation
import os

public actor KbCache {
    private let db: SqliteDatabase
    private let log = Loggers.library

    public init(db: SqliteDatabase) {
        self.db = db
    }

    public func shouldEmbed(chunk: KbChunk, config: EmbeddingConfig) async throws -> Bool {
        let sql = """
            SELECT e.config_fingerprint
              FROM kb_chunks AS c
              JOIN kb_embeddings AS e ON e.chunk_id = c.id
             WHERE c.source_file = ? AND c.source_sha256 = ?
             LIMIT 1
            """
        return try await db.withStatement(sql: sql) { stmt in
            try stmt.bind(text: chunk.sourceFile, at: 1)
            try stmt.bind(text: chunk.sourceSha256, at: 2)
            let res = try stmt.step()
            guard res == .row, let fingerprint = stmt.columnText(at: 0) else {
                return true
            }
            return fingerprint != config.fingerprint
        }
    }

    public func upsert(
        chunk: KbChunk,
        embedding: KbEmbedding,
        config: EmbeddingConfig
    ) async throws {
        precondition(
            embedding.configFingerprint == config.fingerprint,
            "embedding fingerprint must match config fingerprint at insert time"
        )
        let chunkSql = """
            INSERT OR REPLACE INTO kb_chunks
                (id, source_file, breadcrumb, text, source_sha256, created_at,
                 source_kind, project_id, meeting_id, speaker, ts_seconds, title, started_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        try await db.withStatement(sql: chunkSql) { stmt in
            try stmt.bind(text: chunk.id, at: 1)
            try stmt.bind(text: chunk.sourceFile, at: 2)
            try stmt.bind(text: chunk.breadcrumb, at: 3)
            try stmt.bind(text: chunk.text, at: 4)
            try stmt.bind(text: chunk.sourceSha256, at: 5)
            try stmt.bind(int64: Int64(Date().timeIntervalSince1970), at: 6)
            try stmt.bind(text: chunk.sourceKind.rawValue, at: 7)
            try stmt.bind(optionalText: chunk.projectId, at: 8)
            try stmt.bind(optionalText: chunk.meetingId, at: 9)
            try stmt.bind(optionalText: chunk.speaker, at: 10)
            try stmt.bind(optionalDouble: chunk.tsSeconds, at: 11)
            try stmt.bind(optionalText: chunk.title, at: 12)
            try stmt.bind(optionalInt64: chunk.startedAt.map { Int64($0.timeIntervalSince1970) }, at: 13)
            _ = try stmt.step()
        }
        let embSql = """
            INSERT OR REPLACE INTO kb_embeddings
                (chunk_id, vector, config_fingerprint, dim)
            VALUES (?, ?, ?, ?)
            """
        let blob = Self.encode(vector: embedding.vector)
        try await db.withStatement(sql: embSql) { stmt in
            try stmt.bind(text: embedding.chunkId, at: 1)
            try stmt.bind(data: blob, at: 2)
            try stmt.bind(text: embedding.configFingerprint, at: 3)
            try stmt.bind(int64: Int64(embedding.vector.count), at: 4)
            _ = try stmt.step()
        }
    }

    /// Prune the **playbook** corpus down to exactly `keeping` (the live folders'
    /// files).
    ///
    /// Scoped to `source_kind = 'playbook'` so it never touches
    /// meeting-derived chunks (transcript / notes / summary) that share the
    /// `kb_chunks` table — those are owned by ``deleteByMeeting`` /
    /// ``deleteByMeetingSource``. An empty `keeping` set means "no playbook
    /// folders" and clears every playbook row (meetings still survive).
    public func pruneObsolete(keeping: [(file: String, sha: String)]) async throws {
        let playbookKind = KbChunk.SourceKind.playbook.rawValue
        guard !keeping.isEmpty else {
            try await db.withStatement(
                sql: "DELETE FROM kb_embeddings WHERE chunk_id IN (SELECT id FROM kb_chunks WHERE source_kind = ?)"
            ) { stmt in
                try stmt.bind(text: playbookKind, at: 1)
                _ = try stmt.step()
            }
            try await db.withStatement(sql: "DELETE FROM kb_chunks WHERE source_kind = ?") { stmt in
                try stmt.bind(text: playbookKind, at: 1)
                _ = try stmt.step()
            }
            return
        }
        try await db.exec(sql: "CREATE TEMP TABLE IF NOT EXISTS _keep (f TEXT, s TEXT)")
        try await db.exec(sql: "DELETE FROM _keep")
        for entry in keeping {
            try await db.withStatement(sql: "INSERT INTO _keep VALUES (?, ?)") { stmt in
                try stmt.bind(text: entry.file, at: 1)
                try stmt.bind(text: entry.sha, at: 2)
                _ = try stmt.step()
            }
        }
        try await db.withStatement(
            sql: """
                DELETE FROM kb_embeddings WHERE chunk_id IN (
                  SELECT c.id FROM kb_chunks AS c
                  LEFT JOIN _keep AS k ON k.f = c.source_file AND k.s = c.source_sha256
                  WHERE k.f IS NULL AND c.source_kind = ?
                )
                """
        ) { stmt in
            try stmt.bind(text: playbookKind, at: 1)
            _ = try stmt.step()
        }
        try await db.withStatement(
            sql: """
                DELETE FROM kb_chunks WHERE id IN (
                  SELECT c.id FROM kb_chunks AS c
                  LEFT JOIN _keep AS k ON k.f = c.source_file AND k.s = c.source_sha256
                  WHERE k.f IS NULL AND c.source_kind = ?
                )
                """
        ) { stmt in
            try stmt.bind(text: playbookKind, at: 1)
            _ = try stmt.step()
        }
    }

    /// The content hashes already indexed for a playbook source file.
    ///
    /// Lets the
    /// indexer spare a transiently-unreadable file's chunks from the prune (a sync
    /// lock or permission blip shouldn't delete that document's grounding).
    public func shasForFile(_ sourceFile: String) async throws -> Set<String> {
        try await db.withStatement(
            sql: """
                SELECT DISTINCT source_sha256 FROM kb_chunks
                 WHERE source_file = ? AND source_kind = ?
                """
        ) { stmt in
            try stmt.bind(text: sourceFile, at: 1)
            try stmt.bind(text: KbChunk.SourceKind.playbook.rawValue, at: 2)
            var out: Set<String> = []
            while try stmt.step() == .row {
                if let sha = stmt.columnText(at: 0) { out.insert(sha) }
            }
            return out
        }
    }

    public func cachedChunkCount(file: String) async throws -> Int {
        try await db.withStatement(sql: "SELECT COUNT(*) FROM kb_chunks WHERE source_file = ?") { stmt in
            try stmt.bind(text: file, at: 1)
            let res = try stmt.step()
            return res == .row ? stmt.columnInt(at: 0) : 0
        }
    }

    public func loadValid(config: EmbeddingConfig) async throws -> [(KbChunk, KbEmbedding)] {
        let sql = """
            SELECT c.id, c.source_file, c.breadcrumb, c.text, c.source_sha256,
                   e.vector, e.config_fingerprint,
                   c.source_kind, c.project_id, c.meeting_id, c.speaker,
                   c.ts_seconds, c.title, c.started_at
              FROM kb_chunks AS c
              JOIN kb_embeddings AS e ON e.chunk_id = c.id
             WHERE e.config_fingerprint = ?
            """
        return try await db.withStatement(sql: sql) { stmt in
            try stmt.bind(text: config.fingerprint, at: 1)
            var out: [(KbChunk, KbEmbedding)] = []
            while try stmt.step() == .row {
                guard
                    let id = stmt.columnText(at: 0),
                    let file = stmt.columnText(at: 1),
                    let crumb = stmt.columnText(at: 2),
                    let text = stmt.columnText(at: 3),
                    let sha = stmt.columnText(at: 4),
                    let fingerprint = stmt.columnText(at: 6)
                else { continue }
                let blob = stmt.columnBlob(at: 5)
                let vec = Self.decode(blob: blob)
                let kind = KbChunk.SourceKind(rawValue: stmt.columnText(at: 7) ?? "playbook") ?? .playbook
                let startedAt = stmt.columnOptionalInt64(at: 13)
                    .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let chunk = KbChunk(
                    id: id, sourceFile: file, breadcrumb: crumb, text: text, sourceSha256: sha,
                    sourceKind: kind,
                    projectId: stmt.columnText(at: 8),
                    meetingId: stmt.columnText(at: 9),
                    speaker: stmt.columnText(at: 10),
                    tsSeconds: stmt.columnOptionalDouble(at: 11),
                    title: stmt.columnText(at: 12),
                    startedAt: startedAt
                )
                out.append((chunk, KbEmbedding(chunkId: id, vector: vec, configFingerprint: fingerprint)))
            }
            return out
        }
    }

    /// Delete every chunk + embedding for one meeting.
    ///
    /// Used by the meeting
    /// indexer in place of the global ``pruneObsolete`` (which the playbook
    /// indexer owns) so re-indexing a single meeting never touches other
    /// meetings' or playbooks' rows. `kb_embeddings` cascade-deletes via its FK,
    /// but we delete it explicitly too so the purge is correct regardless of the
    /// `foreign_keys` pragma state.
    public func deleteByMeeting(meetingId: String) async throws {
        try await db.withStatement(
            sql: "DELETE FROM kb_embeddings WHERE chunk_id IN (SELECT id FROM kb_chunks WHERE meeting_id = ?)"
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            _ = try stmt.step()
        }
        try await db.withStatement(sql: "DELETE FROM kb_chunks WHERE meeting_id = ?") { stmt in
            try stmt.bind(text: meetingId, at: 1)
            _ = try stmt.step()
        }
    }

    /// Delete one source's chunks within a meeting (e.g. just the notes), leaving
    /// the meeting's other sources intact.
    ///
    /// Lets the indexer re-embed only the
    /// source that changed instead of purging + re-embedding the whole meeting
    /// (BAS-28). `kb_embeddings` cascades via FK; deleted explicitly too so the
    /// purge is correct regardless of the `foreign_keys` pragma state.
    public func deleteByMeetingSource(meetingId: String, sourceFile: String) async throws {
        try await db.withStatement(
            sql: """
                DELETE FROM kb_embeddings WHERE chunk_id IN (
                  SELECT id FROM kb_chunks WHERE meeting_id = ? AND source_file = ?
                )
                """
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            try stmt.bind(text: sourceFile, at: 2)
            _ = try stmt.step()
        }
        try await db.withStatement(
            sql: "DELETE FROM kb_chunks WHERE meeting_id = ? AND source_file = ?"
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            try stmt.bind(text: sourceFile, at: 2)
            _ = try stmt.step()
        }
    }

    /// When a meeting was last successfully indexed (unix seconds), or nil if never.
    ///
    /// The reconcile pass compares this to the max mtime of the meeting's content
    /// files to decide whether to re-read it from disk (BAS-28).
    public func lastIndexedAt(meetingId: String) async throws -> Int64? {
        try await db.withStatement(
            sql: "SELECT last_indexed_at FROM meeting_index_state WHERE meeting_id = ?"
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            guard try stmt.step() == .row else { return nil }
            return stmt.columnInt64(at: 0)
        }
    }

    public func setLastIndexedAt(meetingId: String, at time: Int64) async throws {
        try await db.withStatement(
            sql: """
                INSERT INTO meeting_index_state (meeting_id, last_indexed_at) VALUES (?, ?)
                ON CONFLICT(meeting_id) DO UPDATE SET last_indexed_at = excluded.last_indexed_at
                """
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            try stmt.bind(int64: time, at: 2)
            _ = try stmt.step()
        }
    }

    /// Every meeting's `last_indexed_at` stamp in one query, so the reconcile pass
    /// can gate its per-meeting disk reads from an in-memory map instead of a
    /// round-trip per meeting. `meeting_index_state` is one tiny row per meeting.
    public func allLastIndexedAt() async throws -> [String: Int64] {
        try await db.withStatement(
            sql: "SELECT meeting_id, last_indexed_at FROM meeting_index_state"
        ) { stmt in
            var out: [String: Int64] = [:]
            while try stmt.step() == .row {
                if let id = stmt.columnText(at: 0) { out[id] = stmt.columnInt64(at: 1) }
            }
            return out
        }
    }

    /// The set of `"sourceFile|sha256|fingerprint"` signatures already embedded
    /// for a meeting.
    ///
    /// The meeting indexer compares this to the signatures it
    /// would produce for the current transcript/notes/summary; an exact match
    /// means nothing changed (same content, same embedding model) and indexing
    /// can be skipped entirely.
    public func indexedSignatures(meetingId: String) async throws -> Set<String> {
        let sql = """
            SELECT DISTINCT c.source_file, c.source_sha256, e.config_fingerprint
              FROM kb_chunks AS c
              JOIN kb_embeddings AS e ON e.chunk_id = c.id
             WHERE c.meeting_id = ?
            """
        return try await db.withStatement(sql: sql) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            var out: Set<String> = []
            while try stmt.step() == .row {
                guard let file = stmt.columnText(at: 0),
                    let sha = stmt.columnText(at: 1),
                    let fingerprint = stmt.columnText(at: 2)
                else { continue }
                out.insert("\(file)|\(sha)|\(fingerprint)")
            }
            return out
        }
    }

    /// Session ids of every meeting that already has chunks embedded at `config`'s
    /// fingerprint. Lets the reconcile pass skip re-reading unchanged meetings from
    /// disk on every launch (a content edit is re-indexed at finalize, not here).
    public func indexedMeetingIds(config: EmbeddingConfig) async throws -> Set<String> {
        let sql = """
            SELECT DISTINCT c.meeting_id
              FROM kb_chunks AS c
              JOIN kb_embeddings AS e ON e.chunk_id = c.id
             WHERE c.meeting_id IS NOT NULL AND e.config_fingerprint = ?
            """
        return try await db.withStatement(sql: sql) { stmt in
            try stmt.bind(text: config.fingerprint, at: 1)
            var out: Set<String> = []
            while try stmt.step() == .row {
                if let id = stmt.columnText(at: 0) { out.insert(id) }
            }
            return out
        }
    }

    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func encode(vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(blob: Data) -> [Float] {
        let count = blob.count / MemoryLayout<Float>.size
        return blob.withUnsafeBytes { raw in
            let typed = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: typed.baseAddress, count: count))
        }
    }
}
