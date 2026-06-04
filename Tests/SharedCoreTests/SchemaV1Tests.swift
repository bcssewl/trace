import XCTest

@testable import SharedCore

final class SchemaV1Tests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("schemav1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testBootstrapCreatesAllExpectedTables() async throws {
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("s.sqlite"))
        try await SchemaV1.bootstrap(database: db)

        let expectedTables = [
            "projects", "templates", "meetings", "dictations", "voice_memos",
            "files", "playbooks", "kb_chunks", "kb_embeddings", "transcript_fts", "notes_fts",
            "routing_overrides", "vocab_corrections", "settings_kv", "speakers",
            "dictation_modes",
        ]
        for table in expectedTables {
            let count = try await db.scalarInt(
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE name='\(table)'"
            )
            XCTAssertGreaterThanOrEqual(count, 1, "Table \(table) should exist")
        }
        try await db.close()
    }

    func testBootstrapIsIdempotent() async throws {
        let url = tempDir.appendingPathComponent("s2.sqlite")
        let db1 = try await SqliteDatabase.open(at: url)
        try await SchemaV1.bootstrap(database: db1)
        let mgr1 = MigrationManager(database: db1)
        let v1 = try await mgr1.currentVersion()
        try await db1.close()

        let db2 = try await SqliteDatabase.open(at: url)
        try await SchemaV1.bootstrap(database: db2)
        let mgr2 = MigrationManager(database: db2)
        let v2 = try await mgr2.currentVersion()
        XCTAssertEqual(v1, v2)
        XCTAssertEqual(v1, SchemaV1.migrations.count)
        try await db2.close()
    }

    func testForeignKeyEnforcement() async throws {
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("s3.sqlite"))
        try await SchemaV1.bootstrap(database: db)

        do {
            try await db.withStatement(
                sql: "INSERT INTO meetings (id, project_id, started_at, session_dir_path) VALUES (?, ?, ?, ?)"
            ) { stmt in
                try stmt.bind(text: "m1", at: 1)
                try stmt.bind(text: "nonexistent-project", at: 2)
                try stmt.bind(int64: 0, at: 3)
                try stmt.bind(text: "/tmp", at: 4)
                _ = try stmt.step()
            }
            XCTFail("FK violation should have thrown")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("FOREIGN KEY")
                    || String(describing: error).contains("constraint"),
                "unexpected error: \(error)"
            )
        }
        try await db.close()
    }

    func testTemplatesTableHasPhase3AColumns() async throws {
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("s-tpl.sqlite"))
        try await SchemaV1.bootstrap(database: db)

        var columns: Set<String> = []
        try await db.withStatement(sql: "PRAGMA table_info(templates)") { stmt in
            while try stmt.step() == .row {
                if let name = stmt.columnText(at: 1) {
                    columns.insert(name)
                }
            }
        }
        let required: Set<String> = [
            "id", "name", "description", "is_built_in", "version",
            "forked_from", "system_prompt", "payload_json", "created_at", "updated_at",
        ]
        XCTAssertTrue(required.isSubset(of: columns), "missing columns: \(required.subtracting(columns))")
        try await db.close()
    }

    func testFtsTranscriptInsertAndSearch() async throws {
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("s4.sqlite"))
        try await SchemaV1.bootstrap(database: db)

        try await db.withStatement(
            sql: "INSERT INTO transcript_fts (meeting_id, speaker, text, timestamp) VALUES (?, ?, ?, ?)"
        ) { stmt in
            try stmt.bind(text: "m1", at: 1)
            try stmt.bind(text: "you", at: 2)
            try stmt.bind(text: "hello sarah how are you today", at: 3)
            try stmt.bind(int64: 0, at: 4)
            _ = try stmt.step()
        }

        let matches = try await db.scalarInt(
            sql: "SELECT COUNT(*) FROM transcript_fts WHERE transcript_fts MATCH 'sarah'")
        XCTAssertEqual(matches, 1)
        try await db.close()
    }
}
