import Foundation
import os

/// One persisted Coach playbook *folder* belonging to a project.
///
/// The folder is
/// a directory of Markdown docs the user picked; we hold a security-scoped
/// bookmark to it so read access survives relaunch under the app sandbox.
///
/// `isStale` is meaningful only on values returned by ``PlaybookStore/folders(projectId:)``
/// — when the bookmark resolved but macOS flagged it stale (the folder moved or
/// was re-created), the caller should re-pick the folder to refresh the
/// bookmark. A `nil` `url` means the bookmark could not be resolved at all
/// (e.g. the folder was deleted) — also surfaced as `isStale == true`.
public struct PlaybookFolder: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let projectId: UUID
    /// Display path recorded when the folder was added.
    ///
    /// Always present, even if
    /// the live bookmark no longer resolves.
    public let path: String
    /// Live, security-scoped URL resolved from the bookmark, when available.
    /// `nil` if the bookmark is missing or failed to resolve.
    public let url: URL?
    /// True when the bookmark is stale or unresolvable — the folder should be
    /// re-picked before it can be indexed again.
    public let isStale: Bool
    /// When this folder was added (unix seconds).
    public let createdAt: Int64
    /// Last successful index time (unix seconds), or `nil` if never indexed.
    public let indexedAt: Int64?

    public init(
        id: UUID,
        projectId: UUID,
        path: String,
        url: URL?,
        isStale: Bool,
        createdAt: Int64,
        indexedAt: Int64?
    ) {
        self.id = id
        self.projectId = projectId
        self.path = path
        self.url = url
        self.isStale = isStale
        self.createdAt = createdAt
        self.indexedAt = indexedAt
    }
}

/// Persists and indexes a project's Coach playbook folders.
///
/// Storage lives in the existing `playbooks` table (base migration v7, extended
/// by ``SchemaV18`` with `bookmark_data` + `created_at`). Each row is one
/// folder: `source_path` holds the display path, `bookmark_data` the
/// security-scoped bookmark blob, `project_id` the owning project. The legacy
/// `sha256` column (declared `NOT NULL` for the original per-document design)
/// is written as the empty string for folder rows.
///
/// Indexing delegates entirely to ``KnowledgeBaseIndexer`` — this store never
/// re-implements chunking or embedding. It resolves the relevant folders'
/// bookmarks (balancing security-scope start/stop), hands the resolved directory
/// URLs to `indexer.index(folders:)` in a single pass, and records `indexed_at`.
///
/// ## One global corpus (BAS-18)
/// `kb_chunks` is a shared table with no `project_id` for playbook rows; playbook
/// chunks form one **global reference corpus** the Coach + Q&A retrieve from
/// (`QASearchPipeline` treats playbooks as global, never project-excluded). The
/// indexer's prune is scoped to playbook rows (meeting chunks are untouched) and
/// runs once over the *union* of all presented folders, so multiple folders — and
/// multiple projects — co-exist in the index. Because the prune spans the whole
/// playbook corpus, ``index(projectId:into:)`` is normally called with `nil`
/// (every folder) by the app; handing it one project at a time would prune the
/// other projects' playbook chunks. The folder *records* remain fully
/// project-isolated regardless; only the retrieval corpus is global.
/// (Per-project grounding scope is tracked separately.)
public actor PlaybookStore {

    private let database: SqliteDatabase
    private let bookmarkFactory: @Sendable (URL) throws -> SecurityScopedBookmark
    private var schemaEnsured = false
    private let log = Loggers.library

    /// - Parameters:
    ///   - database: the shared SQLite database (already opened).
    ///   - bookmarkFactory: injectable bookmark creation, defaulting to
    ///     `SecurityScopedBookmark.make(from:)`. Tests pass a stub so they can
    ///     exercise persistence with a plain temp-directory URL without the
    ///     sandbox machinery.
    public init(
        database: SqliteDatabase,
        bookmarkFactory: @escaping @Sendable (URL) throws -> SecurityScopedBookmark = {
            try SecurityScopedBookmark.make(from: $0)
        }
    ) {
        self.database = database
        self.bookmarkFactory = bookmarkFactory
    }

    /// Idempotently ensures the `playbooks` folder columns exist.
    ///
    /// Run lazily on
    /// first use so the store is self-contained even if the app launch path has
    /// not separately applied ``SchemaV18``.
    public func ensureSchema() async throws {
        guard !schemaEnsured else { return }
        try await SchemaV18.bootstrap(database: database)
        schemaEnsured = true
    }

    // MARK: - Folder records

    /// Adds a folder to a project: creates a security-scoped bookmark for `url`
    /// and persists a row (path + bookmark blob + project_id + created time).
    @discardableResult
    public func addFolder(projectId: UUID, url: URL) async throws -> PlaybookFolder {
        try await ensureSchema()

        let standardized = url.standardizedFileURL
        let bookmark = try bookmarkFactory(standardized)
        let id = UUID()
        let now = Int64(Date().timeIntervalSince1970)
        let title =
            standardized.lastPathComponent.isEmpty
            ? standardized.path
            : standardized.lastPathComponent

        try await database.withStatement(
            sql: """
                INSERT INTO playbooks
                    (id, project_id, title, source_path, sha256, bookmark_data, created_at, indexed_at)
                VALUES (?, ?, ?, ?, '', ?, ?, NULL)
                """
        ) { stmt in
            try stmt.bind(text: id.uuidString, at: 1)
            try stmt.bind(text: projectId.uuidString, at: 2)
            try stmt.bind(text: title, at: 3)
            try stmt.bind(text: standardized.path, at: 4)
            try stmt.bind(data: bookmark.bookmarkData, at: 5)
            try stmt.bind(int64: now, at: 6)
            _ = try stmt.step()
        }

        log.info(
            "added playbook folder \(standardized.path, privacy: .public) to project \(projectId.uuidString, privacy: .public)"
        )
        return PlaybookFolder(
            id: id,
            projectId: projectId,
            path: standardized.path,
            url: standardized,
            isStale: false,
            createdAt: now,
            indexedAt: nil
        )
    }

    /// Lists a project's folders, resolving each bookmark to a live URL and
    /// flagging stale / unresolvable ones.
    ///
    /// Resolution start/stop of security
    /// scope is balanced internally — the returned `url` is the bookmark's
    /// resolved location, safe to display; re-resolve via ``resolvedFolder(id:)``
    /// when you actually need to read its contents.
    public func folders(projectId: UUID) async throws -> [PlaybookFolder] {
        try await ensureSchema()

        struct Row: Sendable {
            let id: UUID
            let path: String
            let bookmark: Data
            let createdAt: Int64
            let indexedAt: Int64?
        }

        let rows = try await database.withStatement(
            sql: """
                SELECT id, source_path, bookmark_data, created_at, indexed_at
                  FROM playbooks
                 WHERE project_id = ?
                 ORDER BY created_at ASC
                """
        ) { stmt -> [Row] in
            try stmt.bind(text: projectId.uuidString, at: 1)
            var out: [Row] = []
            while try stmt.step() == .row {
                guard let idText = stmt.columnText(at: 0), let id = UUID(uuidString: idText),
                    let path = stmt.columnText(at: 1)
                else { continue }
                out.append(
                    Row(
                        id: id,
                        path: path,
                        bookmark: stmt.columnBlob(at: 2),
                        createdAt: stmt.columnInt64(at: 3),
                        indexedAt: stmt.columnOptionalInt64(at: 4)
                    ))
            }
            return out
        }

        return rows.map { row in
            var resolvedURL: URL?
            var stale = true
            if !row.bookmark.isEmpty {
                let bm = SecurityScopedBookmark(bookmarkData: row.bookmark, originalPath: row.path)
                if let resolved = try? bm.resolve() {
                    // `resolved` started security-scoped access; releasing the
                    // strong reference at end of this closure stops it (the
                    // ResolvedFolder deinit balances the start). We only need
                    // the URL + stale flag for listing.
                    resolvedURL = resolved.url
                    stale = resolved.isStale
                }
            }
            return PlaybookFolder(
                id: row.id,
                projectId: projectId,
                path: row.path,
                url: resolvedURL,
                isStale: stale,
                createdAt: row.createdAt,
                indexedAt: row.indexedAt
            )
        }
    }

    /// Removes a folder record by id.
    ///
    /// Does not touch already-indexed chunks
    /// (re-running ``index(projectId:into:)`` reconciles the knowledge base).
    public func removeFolder(id: UUID) async throws {
        try await ensureSchema()
        try await database.withStatement(sql: "DELETE FROM playbooks WHERE id = ?") { stmt in
            try stmt.bind(text: id.uuidString, at: 1)
            _ = try stmt.step()
        }
    }

    // MARK: - Resolution

    /// Resolves a single folder's bookmark into a security-scoped
    /// ``ResolvedFolder``.
    ///
    /// The caller **must keep the returned handle alive**
    /// while reading the directory — its `deinit` releases the security scope.
    /// Returns `nil` if the row is missing or has no usable bookmark.
    public func resolvedFolder(id: UUID) async throws -> ResolvedFolder? {
        try await ensureSchema()
        let blob = try await database.withStatement(
            sql: """
                SELECT bookmark_data, source_path FROM playbooks WHERE id = ?
                """
        ) { stmt -> (Data, String)? in
            try stmt.bind(text: id.uuidString, at: 1)
            guard try stmt.step() == .row else { return nil }
            return (stmt.columnBlob(at: 0), stmt.columnText(at: 1) ?? "")
        }
        guard let blob, !blob.0.isEmpty else { return nil }
        let bm = SecurityScopedBookmark(bookmarkData: blob.0, originalPath: blob.1)
        return try bm.resolve()
    }

    /// Resolve a playbook chunk's relative `source_file` (e.g. `sales/pricing.md`)
    /// to an absolute file URL by scanning every indexed folder — across all
    /// projects, since `kb_chunks` carries no project id for playbooks — for a
    /// folder whose root contains that path.
    ///
    /// Returns the first existing match, or
    /// nil if none resolve / exist.
    ///
    /// Security scope is started only for the existence check and released as each
    /// `ResolvedFolder` is dropped; the returned URL is handed to NSWorkspace
    /// (LaunchServices), which opens it without needing our process's scope. Used
    /// by the Library Q&A "open playbook" citation action (BAS-27).
    public func locateFile(relativePath: String) async throws -> URL? {
        try await ensureSchema()
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let rows = try await database.withStatement(
            sql: """
                SELECT bookmark_data, source_path FROM playbooks
                 WHERE bookmark_data IS NOT NULL AND LENGTH(bookmark_data) > 0
                """
        ) { stmt -> [(Data, String)] in
            var out: [(Data, String)] = []
            while try stmt.step() == .row {
                out.append((stmt.columnBlob(at: 0), stmt.columnText(at: 1) ?? ""))
            }
            return out
        }

        for (data, path) in rows where !data.isEmpty {
            let bookmark = SecurityScopedBookmark(bookmarkData: data, originalPath: path)
            guard let resolved = try? bookmark.resolve() else { continue }
            let candidate = resolved.url.appendingPathComponent(trimmed)
            let exists = FileManager.default.fileExists(atPath: candidate.path)
            withExtendedLifetime(resolved) {}
            if exists { return candidate }
        }
        return nil
    }

    // MARK: - Indexing

    /// (Re)indexes resolvable playbook folders into the shared `kb_chunks` corpus
    /// via ``KnowledgeBaseIndexer``, returning the indexer's report (so callers can
    /// read `indexed` for display and gate a vector-index refresh on `embedded`).
    ///
    /// - Parameter projectId: a specific project, or **nil for the whole corpus**
    ///   (every project's folders). The app indexes the whole corpus on launch /
    ///   on add, because the playbook prune is global to playbook rows — handing
    ///   the indexer one project at a time would prune the *other* projects'
    ///   playbook chunks. Per-project is retained for callers that intend exactly
    ///   that scope.
    ///
    /// All resolvable folders are presented to `indexer.index(folders:)` in a
    /// single pass (one unioned prune); stale / unresolvable folders are skipped
    /// (and logged), and successfully-indexed folders get their `indexed_at`
    /// stamped. When there are genuinely no folder records the corpus is cleared;
    /// a transient resolve failure (folders exist but none resolve) is a no-op so
    /// a stale-bookmark hiccup doesn't wipe still-registered playbooks.
    @discardableResult
    public func index(projectId: UUID?, into indexer: KnowledgeBaseIndexer) async throws -> KnowledgeBaseIndexer.Report
    {
        try await ensureSchema()
        let ids = try await folderIDs(projectId: projectId)
        var urls: [URL] = []
        var handles: [ResolvedFolder] = []
        var resolvedIDs: [UUID] = []
        for id in ids {
            guard let resolved = try? await resolvedFolder(id: id) else {
                log.error("skipping unresolvable playbook folder \(id.uuidString, privacy: .public)")
                continue
            }
            urls.append(resolved.url)
            handles.append(resolved)
            resolvedIDs.append(id)
        }
        guard !urls.isEmpty else {
            // No resolvable folders. Only clear the corpus when there are no folder
            // records at all (an empty keep set prunes every playbook row); skip on
            // a resolve failure so we don't wipe folders that are merely stale.
            return ids.isEmpty ? try await indexer.index(folders: []) : KnowledgeBaseIndexer.Report()
        }
        // `handles` hold security scope open for the whole indexing pass.
        let report = try await indexer.index(folders: urls)
        let now = Int64(Date().timeIntervalSince1970)
        for id in resolvedIDs { try await stampIndexed(id: id, at: now) }
        withExtendedLifetime(handles) {}
        return report
    }

    /// Folder ids for one project, or every project's folders when `projectId` is
    /// nil.
    ///
    /// Ordered by creation so indexing precedence is stable.
    private func folderIDs(projectId: UUID?) async throws -> [UUID] {
        let sql =
            projectId == nil
            ? "SELECT id FROM playbooks ORDER BY created_at ASC"
            : "SELECT id FROM playbooks WHERE project_id = ? ORDER BY created_at ASC"
        return try await database.withStatement(sql: sql) { stmt in
            if let projectId { try stmt.bind(text: projectId.uuidString, at: 1) }
            var out: [UUID] = []
            while try stmt.step() == .row {
                if let text = stmt.columnText(at: 0), let id = UUID(uuidString: text) { out.append(id) }
            }
            return out
        }
    }

    private func stampIndexed(id: UUID, at time: Int64) async throws {
        try await database.withStatement(sql: "UPDATE playbooks SET indexed_at = ? WHERE id = ?") { stmt in
            try stmt.bind(int64: time, at: 1)
            try stmt.bind(text: id.uuidString, at: 2)
            _ = try stmt.step()
        }
    }
}
