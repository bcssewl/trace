import Foundation
import os

/// Reconciles `entry_fts` (BAS-26) from the three whole-item library sources:
/// dictations (in-DB `cleaned_text`/`raw_text`), transcribed files, and voice
/// memos (transcript on disk at `transcript_path`).
///
/// Change-gated so a steady-state pass is cheap: dictations are keyed by a content
/// SHA; on-disk transcripts by an `mtime|size` stamp computed from a `stat`, so an
/// unchanged file is never re-read or re-tokenized. Rows whose owning item has
/// disappeared (deleted dictation, removed transcript) are pruned. The transcript
/// indexer's whole-item analogue of `MeetingChunkIndexer`.
public actor LibraryEntryIndexer {

    public struct Report: Sendable {
        /// Rows upserted (new or content-changed).
        public var indexed = 0
        /// Rows removed because their item no longer exists / has no text.
        public var pruned = 0
        /// Items left untouched because their signature matched.
        public var skipped = 0
    }

    /// One item the index should contain. `loadText` is deferred so an unchanged
    /// on-disk transcript (sig match) is never actually read.
    private struct Desired {
        let itemId: String
        let source: LibraryItem.Source
        let projectId: String?
        let title: String
        let startedAt: Int64
        let sig: String
        let loadText: () -> String?
    }

    private let db: SqliteDatabase
    private let log = Loggers.library

    public init(db: SqliteDatabase) {
        self.db = db
    }

    @discardableResult
    public func reconcile() async throws -> Report {
        var report = Report()
        let existing = try await existingSignatures()
        var seen: Set<String> = []

        for entry in try await gatherDesired() {
            seen.insert(entry.itemId)
            if existing[entry.itemId] == entry.sig {
                report.skipped += 1
                continue
            }
            let text = entry.loadText()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                // Item exists but yields no indexable text (empty dictation,
                // unreadable transcript): drop any stale row, don't index.
                if existing[entry.itemId] != nil {
                    try await deleteEntry(entry.itemId)
                    report.pruned += 1
                }
                continue
            }
            try await upsertEntry(entry, text: text)
            report.indexed += 1
        }

        // Prune rows whose owning item is gone from every source table.
        for itemId in existing.keys where !seen.contains(itemId) {
            try await deleteEntry(itemId)
            report.pruned += 1
        }

        if report.indexed > 0 || report.pruned > 0 {
            log.info(
                "entry index reconcile: \(report.indexed) indexed, \(report.pruned) pruned, \(report.skipped) unchanged"
            )
        }
        return report
    }

    // MARK: - Existing state

    private func existingSignatures() async throws -> [String: String] {
        try await db.withStatement(sql: "SELECT item_id, sig FROM entry_fts") { stmt in
            var out: [String: String] = [:]
            while try stmt.step() == .row {
                if let id = stmt.columnText(at: 0) { out[id] = stmt.columnText(at: 1) ?? "" }
            }
            return out
        }
    }

    // MARK: - Desired state

    private func gatherDesired() async throws -> [Desired] {
        var all: [Desired] = []
        all += try await gatherDictations()
        all += try await gatherTranscriptFiles(
            table: "files", source: .file, timeColumn: "created_at",
            statusFilter: "status = 'completed' AND "
        )
        all += try await gatherTranscriptFiles(
            table: "voice_memos", source: .voiceMemo, timeColumn: "started_at",
            statusFilter: ""
        )
        return all
    }

    private func gatherDictations() async throws -> [Desired] {
        // Return Sendable raw rows from the DB actor, then build the (non-Sendable,
        // closure-bearing) Desired values here on this actor.
        let rows = try await db.withStatement(
            sql: """
                SELECT id, project_id, cleaned_text, raw_text, started_at FROM dictations
                """
        ) { stmt -> [(String, String?, String, String, Int64)] in
            var out: [(String, String?, String, String, Int64)] = []
            while try stmt.step() == .row {
                guard let id = stmt.columnText(at: 0) else { continue }
                out.append(
                    (
                        id, stmt.columnText(at: 1),
                        stmt.columnText(at: 2) ?? "", stmt.columnText(at: 3) ?? "",
                        stmt.columnInt64(at: 4)
                    ))
            }
            return out
        }
        return rows.compactMap { id, projectId, cleaned, raw, startedAt in
            let trimmedCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (trimmedCleaned.isEmpty ? raw : cleaned)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Desired(
                itemId: id, source: .dictation, projectId: projectId,
                title: Self.title(fromText: text), startedAt: startedAt,
                sig: KbCache.sha256Hex(of: Data(text.utf8)),
                loadText: { text }
            )
        }
    }

    /// `files` + `voice_memos` share a shape: a `transcript_path` to a text file
    /// on disk.
    ///
    /// Signature is `mtime|size` from a `stat` so an unchanged transcript
    /// is never read; rows with a missing / unreadable file are dropped (and so
    /// pruned from the index).
    private func gatherTranscriptFiles(
        table: String, source: LibraryItem.Source, timeColumn: String, statusFilter: String
    ) async throws -> [Desired] {
        let sql = """
            SELECT id, project_id, title, transcript_path, \(timeColumn)
              FROM \(table)
             WHERE \(statusFilter)transcript_path IS NOT NULL AND transcript_path <> ''
            """
        let rows = try await db.withStatement(sql: sql) { stmt -> [(String, String?, String?, String, Int64)] in
            var out: [(String, String?, String?, String, Int64)] = []
            while try stmt.step() == .row {
                guard let id = stmt.columnText(at: 0), let path = stmt.columnText(at: 3) else { continue }
                out.append((id, stmt.columnText(at: 1), stmt.columnText(at: 2), path, stmt.columnInt64(at: 4)))
            }
            return out
        }

        return rows.compactMap { id, projectId, title, path, startedAt in
            guard let sig = Self.fileSignature(path) else { return nil }
            return Desired(
                itemId: id, source: source, projectId: projectId,
                title: title.flatMap { $0.isEmpty ? nil : $0 } ?? Self.title(fromPath: path),
                startedAt: startedAt, sig: sig,
                loadText: { try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) }
            )
        }
    }

    // MARK: - Writes

    private func upsertEntry(_ entry: Desired, text: String) async throws {
        // Bind through Sendable locals so the statement closures don't capture the
        // non-Sendable Desired (its `loadText`).
        let (itemId, source, projectId) = (entry.itemId, entry.source, entry.projectId)
        let (title, startedAt, sig) = (entry.title, entry.startedAt, entry.sig)
        // Delete + insert in one transaction so a crash can't drop the item
        // from keyword search until the next signature change.
        try await db.transaction {
            try await deleteEntry(itemId)
            try await db.withStatement(
                sql: """
                    INSERT INTO entry_fts (item_id, source, project_id, title, started_at, sig, text)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """
            ) { stmt in
                try stmt.bind(text: itemId, at: 1)
                try stmt.bind(text: source.rawValue, at: 2)
                try stmt.bind(optionalText: projectId, at: 3)
                try stmt.bind(text: title, at: 4)
                try stmt.bind(int64: startedAt, at: 5)
                try stmt.bind(text: sig, at: 6)
                try stmt.bind(text: text, at: 7)
                _ = try stmt.step()
            }
        }
    }

    private func deleteEntry(_ itemId: String) async throws {
        try await db.withStatement(sql: "DELETE FROM entry_fts WHERE item_id = ?") { stmt in
            try stmt.bind(text: itemId, at: 1)
            _ = try stmt.step()
        }
    }

    // MARK: - Helpers

    /// `mtime|size` from a `stat`, or nil if the file is missing / unreadable —
    /// cheap enough to recompute every pass without reading the file's contents.
    private static func fileSignature(_ path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? Int
        else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(Int(mtime))|\(size)"
    }

    private static func title(fromText text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(oneLine.prefix(80))
        return clipped.isEmpty ? "Untitled" : clipped
    }

    private static func title(fromPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "Transcript" : name
    }
}
