import Foundation

public struct TranscriptHit: Sendable, Hashable {
    public let meetingId: String
    public let speaker: String
    public let text: String
    public let timestamp: Double
    public let rank: Double
}

public struct NotesHit: Sendable, Hashable {
    public let meetingId: String
    public let text: String
    public let rank: Double
}

public struct FtsIndex: Sendable {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) {
        self.database = database
    }

    public func insertTranscript(meetingId: String, speaker: String, text: String, timestamp: Double) async throws {
        try await database.withStatement(
            sql: "INSERT INTO transcript_fts (meeting_id, speaker, text, timestamp) VALUES (?, ?, ?, ?)"
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            try stmt.bind(text: speaker, at: 2)
            try stmt.bind(text: text, at: 3)
            try stmt.bind(double: timestamp, at: 4)
            _ = try stmt.step()
        }
    }

    public func deleteTranscript(meetingId: String) async throws {
        try await database.withStatement(
            sql: "DELETE FROM transcript_fts WHERE meeting_id = ?"
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            _ = try stmt.step()
        }
    }

    public func deleteNotes(meetingId: String) async throws {
        try await database.withStatement(
            sql: "DELETE FROM notes_fts WHERE meeting_id = ?"
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            _ = try stmt.step()
        }
    }

    public func searchTranscript(
        query: String, limit: Int = 50, meetingId: String? = nil
    ) async throws -> [TranscriptHit] {
        var hits: [TranscriptHit] = []
        let sql: String
        if meetingId != nil {
            sql = """
                    SELECT meeting_id, speaker, text, timestamp, rank
                    FROM transcript_fts
                    WHERE transcript_fts MATCH ? AND meeting_id = ?
                    ORDER BY rank
                    LIMIT ?
                """
        } else {
            sql = """
                    SELECT meeting_id, speaker, text, timestamp, rank
                    FROM transcript_fts
                    WHERE transcript_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                """
        }
        try await database.withStatement(sql: sql) { stmt in
            try stmt.bind(text: query, at: 1)
            if let mid = meetingId {
                try stmt.bind(text: mid, at: 2)
                try stmt.bind(int: limit, at: 3)
            } else {
                try stmt.bind(int: limit, at: 2)
            }
            while try stmt.step() == .row {
                hits.append(
                    TranscriptHit(
                        meetingId: stmt.columnTextRequired(at: 0),
                        speaker: stmt.columnTextRequired(at: 1),
                        text: stmt.columnTextRequired(at: 2),
                        timestamp: stmt.columnDouble(at: 3),
                        rank: stmt.columnDouble(at: 4)
                    ))
            }
        }
        return hits
    }

    public func upsertNotes(meetingId: String, text: String) async throws {
        // One transaction: a crash between the DELETE and the INSERT must not
        // leave the meeting's notes silently missing from search.
        try await database.transaction {
            try await database.withStatement(
                sql: "DELETE FROM notes_fts WHERE meeting_id = ?"
            ) { stmt in
                try stmt.bind(text: meetingId, at: 1)
                _ = try stmt.step()
            }
            try await database.withStatement(
                sql: "INSERT INTO notes_fts (meeting_id, text) VALUES (?, ?)"
            ) { stmt in
                try stmt.bind(text: meetingId, at: 1)
                try stmt.bind(text: text, at: 2)
                _ = try stmt.step()
            }
        }
    }

    /// Number of indexed transcript rows for one meeting — the reconciler's
    /// cheap "does the index match the JSONL?" probe.
    public func transcriptRowCount(meetingId: String) async throws -> Int {
        try await database.withStatement(
            sql: "SELECT COUNT(*) FROM transcript_fts WHERE meeting_id = ?"
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            let res = try stmt.step()
            return res == .row ? stmt.columnInt(at: 0) : 0
        }
    }

    /// The currently indexed notes text for one meeting (nil when unindexed).
    public func notesText(meetingId: String) async throws -> String? {
        try await database.withStatement(
            sql: "SELECT text FROM notes_fts WHERE meeting_id = ? LIMIT 1"
        ) { stmt in
            try stmt.bind(text: meetingId, at: 1)
            guard try stmt.step() == .row else { return nil }
            return stmt.columnText(at: 0)
        }
    }

    public func searchNotes(query: String, limit: Int = 50) async throws -> [NotesHit] {
        var hits: [NotesHit] = []
        try await database.withStatement(
            sql: """
                    SELECT meeting_id, text, rank
                    FROM notes_fts
                    WHERE notes_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                """
        ) { stmt in
            try stmt.bind(text: query, at: 1)
            try stmt.bind(int: limit, at: 2)
            while try stmt.step() == .row {
                hits.append(
                    NotesHit(
                        meetingId: stmt.columnTextRequired(at: 0),
                        text: stmt.columnTextRequired(at: 1),
                        rank: stmt.columnDouble(at: 2)
                    ))
            }
        }
        return hits
    }
}
