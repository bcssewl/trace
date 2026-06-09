import Foundation
import os

/// Launch-time integrity pass over the SQLite index (BAS storage batch).
///
/// SQLite rows and on-disk session content (transcript JSONL, notes.md) can
/// never be written atomically together, so a crash between the two leaves the
/// search index missing, stale, or pointing at deleted content. This actor
/// repairs all of that at boot:
///
/// 1. **Ghost rows** — FTS / vector / state rows whose owning item was deleted
///    (`deleteMeeting` historically never purged `kb_chunks`; a deleted file or
///    dictation left its `entry_fts` row behind until the next entry reconcile),
///    plus `kb_embeddings` orphaned by the old non-transactional prune.
/// 2. **Abandoned meetings** — a crash inside `finalizeSession` leaves
///    `ended_at IS NULL` forever; such meetings are closed using the last
///    utterance timestamp from the canonical JSONL.
/// 3. **FTS ↔ content desync** — per meeting, the transcript FTS row count is
///    verified against the canonical JSONL and `notes_fts` against `notes.md`;
///    mismatches are re-indexed from disk.
///
/// Cheapness: every meeting's transcript/notes `mtime|size` signatures are
/// cached in `fts_reconcile_state` (schema v31); a clean meeting costs two
/// `stat` calls and zero content reads. Call `reconcile()` once at app boot —
/// it is safe to re-run at any time (meetings still open within
/// `activityGrace` of now are treated as live and left alone).
public actor StorageReconciler {

    /// What the pass found and fixed — surface this, don't swallow it.
    public struct Report: Sendable, Equatable {
        /// Meetings checked against their cached signatures.
        public var meetingsChecked = 0
        /// Meetings skipped because their content signatures were unchanged.
        public var meetingsClean = 0
        /// Open meetings closed with a recovered `ended_at`.
        public var abandonedMeetingsClosed = 0
        /// Meetings whose transcript FTS rows were rebuilt from the JSONL.
        public var transcriptsReindexed = 0
        /// Meetings whose notes FTS row was rebuilt from notes.md.
        public var notesReindexed = 0
        /// Ghost rows removed (FTS / entry / chunk / state rows of deleted items).
        public var ghostRowsRemoved = 0
        /// `kb_embeddings` rows whose chunk no longer exists.
        public var orphanEmbeddingsRemoved = 0

        public var didRepairAnything: Bool {
            abandonedMeetingsClosed + transcriptsReindexed + notesReindexed
                + ghostRowsRemoved + orphanEmbeddingsRemoved > 0
        }

        /// One human-readable line for logs / a status surface.
        public var summary: String {
            guard didRepairAnything else {
                return "Library index verified — nothing needed repair."
            }
            var parts: [String] = []
            if abandonedMeetingsClosed > 0 {
                parts.append("closed \(abandonedMeetingsClosed) interrupted meeting\(abandonedMeetingsClosed == 1 ? "" : "s")")
            }
            if transcriptsReindexed > 0 {
                parts.append("re-indexed \(transcriptsReindexed) transcript\(transcriptsReindexed == 1 ? "" : "s")")
            }
            if notesReindexed > 0 {
                parts.append("re-indexed notes for \(notesReindexed) meeting\(notesReindexed == 1 ? "" : "s")")
            }
            if ghostRowsRemoved > 0 {
                parts.append("removed \(ghostRowsRemoved) leftover search entr\(ghostRowsRemoved == 1 ? "y" : "ies")")
            }
            if orphanEmbeddingsRemoved > 0 {
                parts.append("cleaned \(orphanEmbeddingsRemoved) orphaned embedding\(orphanEmbeddingsRemoved == 1 ? "" : "s")")
            }
            return "Library index repaired: " + parts.joined(separator: ", ") + "."
        }
    }

    private let database: SqliteDatabase
    private let fts: FtsIndex
    private let log = Loggers.storage

    public init(database: SqliteDatabase) {
        self.database = database
        self.fts = FtsIndex(database: database)
    }

    /// Run the full pass. Throws on database failure (the caller must surface
    /// it — a broken index is not a silent condition).
    ///
    /// - Parameters:
    ///   - now: injectable clock for tests.
    ///   - activityGrace: an open meeting whose transcript file was modified
    ///     within this window is treated as live and untouched.
    @discardableResult
    public func reconcile(now: Date = Date(), activityGrace: TimeInterval = 120) async throws -> Report {
        var report = Report()
        try await cleanupGhostRows(into: &report)
        try await closeAbandonedMeetings(now: now, grace: activityGrace, into: &report)
        try await verifyAndRepairFts(into: &report)
        if report.didRepairAnything {
            log.warning("Storage reconcile: \(report.summary, privacy: .public)")
        } else {
            log.info("Storage reconcile: clean (\(report.meetingsChecked) meetings checked)")
        }
        return report
    }

    // MARK: - 1. Ghost rows

    /// Delete index rows whose owning item no longer exists. Each statement is
    /// independent, but they run in one transaction so a crash can't leave the
    /// cleanup half-applied.
    private func cleanupGhostRows(into report: inout Report) async throws {
        let database = self.database
        let (ghosts, orphans) = try await database.transaction { () -> (Int, Int) in
            var ghosts = 0
            let ghostSQL = [
                "DELETE FROM transcript_fts WHERE meeting_id NOT IN (SELECT id FROM meetings)",
                "DELETE FROM notes_fts WHERE meeting_id NOT IN (SELECT id FROM meetings)",
                "DELETE FROM entry_fts WHERE source = 'dictation' AND item_id NOT IN (SELECT id FROM dictations)",
                "DELETE FROM entry_fts WHERE source = 'file' AND item_id NOT IN (SELECT id FROM files)",
                "DELETE FROM entry_fts WHERE source = 'voiceMemo' AND item_id NOT IN (SELECT id FROM voice_memos)",
                "DELETE FROM kb_chunks WHERE meeting_id IS NOT NULL AND meeting_id NOT IN (SELECT id FROM meetings)",
                "DELETE FROM meeting_index_state WHERE meeting_id NOT IN (SELECT id FROM meetings)",
                "DELETE FROM fts_reconcile_state WHERE meeting_id NOT IN (SELECT id FROM meetings)",
            ]
            for sql in ghostSQL {
                try await database.exec(sql: sql)
                ghosts += try await database.scalarInt(sql: "SELECT changes()")
            }
            // Embeddings orphaned by chunk deletes (incl. the historical
            // non-transactional pruneObsolete crash window).
            try await database.exec(
                sql: "DELETE FROM kb_embeddings WHERE chunk_id NOT IN (SELECT id FROM kb_chunks)")
            let orphans = try await database.scalarInt(sql: "SELECT changes()")
            return (ghosts, orphans)
        }
        report.ghostRowsRemoved += ghosts
        report.orphanEmbeddingsRemoved += orphans
    }

    // MARK: - 2. Abandoned meetings

    private struct OpenMeeting {
        let id: String
        let startedAt: Int64
        let dirPath: String
    }

    /// Close meetings stuck with `ended_at IS NULL` whose transcript shows no
    /// recent activity. `ended_at` comes from the last utterance's offset; a
    /// meeting with no parseable transcript closes at its start time.
    private func closeAbandonedMeetings(
        now: Date, grace: TimeInterval, into report: inout Report
    ) async throws {
        let open = try await database.withStatement(
            sql: "SELECT id, started_at, session_dir_path FROM meetings WHERE ended_at IS NULL"
        ) { stmt -> [OpenMeeting] in
            var out: [OpenMeeting] = []
            while try stmt.step() == .row {
                guard let id = stmt.columnText(at: 0), let dir = stmt.columnText(at: 2) else { continue }
                out.append(OpenMeeting(id: id, startedAt: stmt.columnInt64(at: 1), dirPath: dir))
            }
            return out
        }

        for meeting in open {
            let dir = URL(fileURLWithPath: meeting.dirPath)
            // Still being written? Leave it — it's (probably) the live meeting.
            if let url = SessionRepository.canonicalTranscriptURL(in: dir),
                let mtime = Self.modificationDate(of: url.path),
                now.timeIntervalSince(mtime) < grace
            {
                continue
            }
            let utterances = SessionRepository.loadTranscript(in: dir)
            let lastOffset = utterances.last.map { max(0, $0.t) } ?? 0
            let endedAt = meeting.startedAt + Int64(lastOffset.rounded())
            try await database.withStatement(
                sql: "UPDATE meetings SET ended_at = ? WHERE id = ? AND ended_at IS NULL"
            ) { stmt in
                try stmt.bind(int64: max(endedAt, meeting.startedAt), at: 1)
                try stmt.bind(text: meeting.id, at: 2)
                _ = try stmt.step()
            }
            report.abandonedMeetingsClosed += 1
            log.warning(
                "Closed abandoned meeting \(meeting.id, privacy: .public) (no finalize ran; ended_at recovered from transcript)"
            )
        }
    }

    // MARK: - 3. FTS ↔ content verification

    private struct ReconcileState {
        let transcriptSig: String
        let notesSig: String
    }

    /// Verify each *finished* meeting's FTS rows against its canonical on-disk
    /// content, repairing what's missing or stale. Open meetings are skipped —
    /// the live pipeline owns their index. A meeting whose session directory
    /// has vanished entirely is left alone (it may live on an unmounted volume;
    /// destroying its index would not be a repair).
    private func verifyAndRepairFts(into report: inout Report) async throws {
        let states = try await loadReconcileStates()
        let meetings = try await database.withStatement(
            sql: "SELECT id, session_dir_path FROM meetings WHERE ended_at IS NOT NULL"
        ) { stmt -> [(String, String)] in
            var out: [(String, String)] = []
            while try stmt.step() == .row {
                guard let id = stmt.columnText(at: 0), let dir = stmt.columnText(at: 1) else { continue }
                out.append((id, dir))
            }
            return out
        }

        for (meetingId, dirPath) in meetings {
            report.meetingsChecked += 1
            let dir = URL(fileURLWithPath: dirPath)
            guard FileManager.default.fileExists(atPath: dir.path) else {
                report.meetingsClean += 1
                continue
            }
            let transcriptSig = SessionRepository.canonicalTranscriptURL(in: dir)
                .flatMap { Self.fileSignature($0.path) } ?? "absent"
            let notesPath = dir.appendingPathComponent("notes.md").path
            let notesSig = Self.fileSignature(notesPath) ?? "absent"

            if let cached = states[meetingId],
                cached.transcriptSig == transcriptSig, cached.notesSig == notesSig
            {
                report.meetingsClean += 1
                continue
            }

            if try await repairTranscriptIfNeeded(meetingId: meetingId, dir: dir) {
                report.transcriptsReindexed += 1
            }
            if try await repairNotesIfNeeded(meetingId: meetingId, notesPath: notesPath) {
                report.notesReindexed += 1
            }
            try await storeReconcileState(
                meetingId: meetingId, transcriptSig: transcriptSig, notesSig: notesSig)
        }
    }

    /// Re-index the transcript when the FTS row count disagrees with the
    /// canonical JSONL. Returns whether a repair ran.
    private func repairTranscriptIfNeeded(meetingId: String, dir: URL) async throws -> Bool {
        guard SessionRepository.canonicalTranscriptURL(in: dir) != nil else { return false }
        let utterances = SessionRepository.loadTranscript(in: dir)
        let indexed = try await fts.transcriptRowCount(meetingId: meetingId)
        guard indexed != utterances.count else { return false }
        try await database.transaction {
            try await fts.deleteTranscript(meetingId: meetingId)
            for utt in utterances {
                try await fts.insertTranscript(
                    meetingId: meetingId,
                    speaker: utt.speaker.rawValue,
                    text: utt.text,
                    timestamp: utt.t
                )
            }
        }
        log.warning(
            "Re-indexed transcript for \(meetingId, privacy: .public): FTS had \(indexed) rows, JSONL has \(utterances.count)"
        )
        return true
    }

    /// Re-index notes when `notes_fts` disagrees with notes.md (or remove the
    /// row when the file is gone). Returns whether a repair ran.
    private func repairNotesIfNeeded(meetingId: String, notesPath: String) async throws -> Bool {
        // Distinguish "the file is genuinely gone" from "the file exists but
        // couldn't be read" (permissions, IO error, unmounted volume): only the
        // former justifies deleting the index row. Treating a transient read
        // failure as absence would delete real notes from search — and the
        // stored signature would make that deletion permanent.
        let exists = FileManager.default.fileExists(atPath: notesPath)
        let onDisk: String?
        if exists {
            do {
                onDisk = try String(contentsOf: URL(fileURLWithPath: notesPath), encoding: .utf8)
            } catch {
                log.error(
                    "notes.md for \(meetingId, privacy: .public) exists but is unreadable — leaving its index untouched: \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        } else {
            onDisk = nil
        }
        let indexed = try await fts.notesText(meetingId: meetingId)
        switch (onDisk, indexed) {
        case (nil, nil):
            return false
        case (nil, .some):
            try await fts.deleteNotes(meetingId: meetingId)
            return true
        case (let .some(content), let current):
            guard current != content else { return false }
            try await fts.upsertNotes(meetingId: meetingId, text: content)
            return true
        }
    }

    private func loadReconcileStates() async throws -> [String: ReconcileState] {
        try await database.withStatement(
            sql: "SELECT meeting_id, transcript_sig, notes_sig FROM fts_reconcile_state"
        ) { stmt in
            var out: [String: ReconcileState] = [:]
            while try stmt.step() == .row {
                guard let id = stmt.columnText(at: 0) else { continue }
                out[id] = ReconcileState(
                    transcriptSig: stmt.columnText(at: 1) ?? "",
                    notesSig: stmt.columnText(at: 2) ?? ""
                )
            }
            return out
        }
    }

    private func storeReconcileState(
        meetingId: String, transcriptSig: String, notesSig: String
    ) async throws {
        try await database.withStatement(
            sql: """
                INSERT INTO fts_reconcile_state (meeting_id, transcript_sig, notes_sig, checked_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(meeting_id) DO UPDATE SET
                    transcript_sig = excluded.transcript_sig,
                    notes_sig = excluded.notes_sig,
                    checked_at = excluded.checked_at
                """
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            try stmt.bind(text: transcriptSig, at: 2)
            try stmt.bind(text: notesSig, at: 3)
            try stmt.bind(int64: Int64(Date().timeIntervalSince1970), at: 4)
            _ = try stmt.step()
        }
    }

    // MARK: - File helpers

    /// `mtime|size` — cheap (one `stat`), and changes whenever content does.
    private static func fileSignature(_ path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? Int
        else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(Int(mtime))|\(size)"
    }

    private static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
