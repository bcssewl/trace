import Foundation

public enum SchemaV1 {
    public static let migrations: [Migration] = [
        Migration(
            version: 1, name: "create_projects",
            sql: """
                    CREATE TABLE projects (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL UNIQUE,
                        indicator_color TEXT NOT NULL,
                        default_template_id TEXT,
                        coach_config TEXT NOT NULL DEFAULT '{}',
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL
                    );
                    CREATE INDEX projects_updated_at ON projects(updated_at DESC);
                """),

        Migration(
            version: 2, name: "create_templates",
            sql: """
                    CREATE TABLE templates (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        description TEXT NOT NULL DEFAULT '',
                        is_built_in INTEGER NOT NULL DEFAULT 0,
                        version TEXT NOT NULL,
                        forked_from TEXT,
                        system_prompt TEXT NOT NULL,
                        payload_json TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        FOREIGN KEY(forked_from) REFERENCES templates(id) ON DELETE SET NULL
                    );
                    CREATE INDEX templates_updated_at_idx ON templates(updated_at DESC);
                    CREATE INDEX templates_built_in ON templates(is_built_in);
                """),

        Migration(
            version: 3, name: "create_meetings",
            sql: """
                    CREATE TABLE meetings (
                        id TEXT PRIMARY KEY,
                        project_id TEXT,
                        title TEXT,
                        started_at INTEGER NOT NULL,
                        ended_at INTEGER,
                        template_id TEXT,
                        calendar_event_id TEXT,
                        auto_categorized_confidence REAL,
                        manual_override INTEGER NOT NULL DEFAULT 0,
                        session_dir_path TEXT NOT NULL,
                        FOREIGN KEY(project_id) REFERENCES projects(id) ON DELETE SET NULL,
                        FOREIGN KEY(template_id) REFERENCES templates(id) ON DELETE SET NULL
                    );
                    CREATE INDEX meetings_project ON meetings(project_id, started_at DESC);
                    CREATE INDEX meetings_started ON meetings(started_at DESC);
                """),

        Migration(
            version: 4, name: "create_dictations",
            sql: """
                    CREATE TABLE dictations (
                        id TEXT PRIMARY KEY,
                        project_id TEXT,
                        mode_name TEXT,
                        bundle_id TEXT,
                        raw_text TEXT NOT NULL,
                        cleaned_text TEXT NOT NULL,
                        inserted INTEGER NOT NULL DEFAULT 0,
                        duration_ms INTEGER NOT NULL,
                        started_at INTEGER NOT NULL,
                        FOREIGN KEY(project_id) REFERENCES projects(id) ON DELETE SET NULL
                    );
                    CREATE INDEX dictations_started ON dictations(started_at DESC);
                """),

        Migration(
            version: 5, name: "create_voice_memos",
            sql: """
                    CREATE TABLE voice_memos (
                        id TEXT PRIMARY KEY,
                        project_id TEXT,
                        title TEXT,
                        file_path TEXT NOT NULL,
                        duration_ms INTEGER NOT NULL,
                        transcript_path TEXT,
                        started_at INTEGER NOT NULL,
                        FOREIGN KEY(project_id) REFERENCES projects(id) ON DELETE SET NULL
                    );
                """),

        Migration(
            version: 6, name: "create_files",
            sql: """
                    CREATE TABLE files (
                        id TEXT PRIMARY KEY,
                        project_id TEXT,
                        title TEXT,
                        source_path TEXT NOT NULL,
                        transcript_path TEXT,
                        engine TEXT NOT NULL,
                        duration_ms INTEGER,
                        status TEXT NOT NULL,
                        error_reason TEXT,
                        created_at INTEGER NOT NULL,
                        completed_at INTEGER,
                        FOREIGN KEY(project_id) REFERENCES projects(id) ON DELETE SET NULL
                    );
                    CREATE INDEX files_status ON files(status);
                """),

        Migration(
            version: 7, name: "create_playbooks",
            sql: """
                    CREATE TABLE playbooks (
                        id TEXT PRIMARY KEY,
                        project_id TEXT NOT NULL,
                        title TEXT NOT NULL,
                        source_path TEXT NOT NULL,
                        sha256 TEXT NOT NULL,
                        indexed_at INTEGER,
                        FOREIGN KEY(project_id) REFERENCES projects(id) ON DELETE CASCADE
                    );
                    CREATE INDEX playbooks_project ON playbooks(project_id);
                """),

        Migration(
            version: 8, name: "create_kb_chunks_and_embeddings",
            sql: """
                    CREATE TABLE kb_chunks (
                        id TEXT PRIMARY KEY,
                        source_file TEXT NOT NULL,
                        breadcrumb TEXT NOT NULL,
                        text TEXT NOT NULL,
                        source_sha256 TEXT NOT NULL,
                        created_at INTEGER NOT NULL
                    );
                    CREATE INDEX kb_chunks_source_file ON kb_chunks(source_file);
                    CREATE INDEX kb_chunks_sha ON kb_chunks(source_sha256);
                    CREATE TABLE kb_embeddings (
                        chunk_id TEXT PRIMARY KEY,
                        vector BLOB NOT NULL,
                        config_fingerprint TEXT NOT NULL,
                        dim INTEGER NOT NULL,
                        FOREIGN KEY(chunk_id) REFERENCES kb_chunks(id) ON DELETE CASCADE
                    );
                    CREATE INDEX kb_embeddings_fingerprint ON kb_embeddings(config_fingerprint);
                """),

        Migration(
            version: 9, name: "create_transcript_fts",
            sql: """
                    CREATE VIRTUAL TABLE transcript_fts USING fts5(
                        meeting_id UNINDEXED,
                        speaker UNINDEXED,
                        text,
                        timestamp UNINDEXED
                    );
                """),

        Migration(
            version: 10, name: "create_notes_fts",
            sql: """
                    CREATE VIRTUAL TABLE notes_fts USING fts5(
                        meeting_id UNINDEXED,
                        text
                    );
                """),

        Migration(
            version: 11, name: "create_routing_overrides",
            sql: """
                    CREATE TABLE routing_overrides (
                        task_class TEXT PRIMARY KEY,
                        provider TEXT NOT NULL,
                        model TEXT,
                        updated_at INTEGER NOT NULL
                    );
                """),

        Migration(
            version: 12, name: "create_vocab_corrections",
            sql: """
                    CREATE TABLE vocab_corrections (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        heard TEXT NOT NULL,
                        corrected TEXT NOT NULL,
                        count INTEGER NOT NULL DEFAULT 1,
                        updated_at INTEGER NOT NULL,
                        UNIQUE(heard, corrected)
                    );
                    CREATE INDEX vocab_heard ON vocab_corrections(heard);
                """),

        Migration(
            version: 13, name: "create_settings_kv",
            sql: """
                    CREATE TABLE settings_kv (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL,
                        updated_at INTEGER NOT NULL
                    );
                """),

        Migration(
            version: 14, name: "create_speakers",
            sql: """
                    CREATE TABLE speakers (
                        id TEXT PRIMARY KEY,
                        project_id TEXT NOT NULL,
                        name TEXT NOT NULL,
                        mean_embedding BLOB NOT NULL,
                        embedding_model TEXT NOT NULL,
                        last_seen_at INTEGER NOT NULL,
                        FOREIGN KEY(project_id) REFERENCES projects(id) ON DELETE CASCADE
                    );
                    CREATE INDEX speakers_project ON speakers(project_id);
                """),

        Migration(
            version: 15, name: "create_dictation_modes",
            sql: """
                    CREATE TABLE dictation_modes (
                        id TEXT PRIMARY KEY,
                        payload_json TEXT NOT NULL,
                        updated_at INTEGER NOT NULL
                    );
                    CREATE INDEX dictation_modes_updated ON dictation_modes(updated_at DESC);
                """),
    ]

    public static func bootstrap(database: SqliteDatabase) async throws {
        let manager = MigrationManager(database: database)
        try await manager.bootstrap()
        try await manager.apply(migrations: migrations)
    }
}
