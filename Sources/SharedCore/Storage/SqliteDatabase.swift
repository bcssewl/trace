import Foundation
import os

#if canImport(SQLite3)
import SQLite3
#endif

public actor SqliteDatabase {
    private var handle: OpaquePointer?
    private var preparedCache: [String: SqliteStatement] = [:]
    private let url: URL
    private var closed = false

    private init(handle: OpaquePointer, url: URL) {
        self.handle = handle
        self.url = url
    }

    public static func open(at url: URL) async throws -> SqliteDatabase {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h = handle { sqlite3_close_v2(h) }
            throw TraceError.storageFailed(reason: "sqlite3_open_v2 failed (rc=\(rc)): \(msg)")
        }

        let db = SqliteDatabase(handle: handle, url: url)
        try await db.configurePragmas()
        Loggers.storage.info("Opened SQLite at \(url.path, privacy: .public)")
        return db
    }

    public func close() throws {
        guard !closed else { return }
        for (_, stmt) in preparedCache {
            try? stmt.finalize()
        }
        preparedCache.removeAll()
        if let h = handle {
            let rc = sqlite3_close_v2(h)
            if rc != SQLITE_OK {
                Loggers.storage.error("sqlite3_close_v2 rc=\(rc)")
            }
        }
        handle = nil
        closed = true
    }

    private func configurePragmas() throws {
        try execInternal("PRAGMA journal_mode = WAL")
        try execInternal("PRAGMA synchronous = NORMAL")
        try execInternal("PRAGMA foreign_keys = ON")
        try execInternal("PRAGMA temp_store = MEMORY")
        try execInternal("PRAGMA cache_size = -20000")
        try execInternal("PRAGMA wal_autocheckpoint = 1000")
        try execInternal("PRAGMA busy_timeout = 5000")
    }

    public func exec(sql: String) throws {
        try execInternal(sql)
    }

    private func execInternal(_ sql: String) throws {
        guard let handle else {
            throw TraceError.storageFailed(reason: "exec on closed database")
        }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TraceError.storageFailed(reason: "exec failed (rc=\(rc)): \(msg) -- SQL: \(sql)")
        }
    }

    public func scalarString(sql: String) throws -> String? {
        try withStatement(sql: sql) { stmt -> String? in
            let res = try stmt.step()
            guard res == .row else { return nil }
            return stmt.columnText(at: 0)
        }
    }

    public func scalarInt(sql: String) throws -> Int {
        try withStatement(sql: sql) { stmt -> Int in
            let res = try stmt.step()
            guard res == .row else { return 0 }
            return stmt.columnInt(at: 0)
        }
    }

    public func withStatement<T>(sql: String, _ body: (SqliteStatement) throws -> T) throws -> T {
        guard let handle else {
            throw TraceError.storageFailed(reason: "withStatement on closed database")
        }
        let stmt: SqliteStatement
        if let cached = preparedCache[sql] {
            stmt = cached
        } else {
            stmt = try SqliteStatement(db: handle, sql: sql)
            preparedCache[sql] = stmt
        }

        do {
            let result = try body(stmt)
            try stmt.reset()
            try stmt.clearBindings()
            return result
        } catch {
            try? stmt.reset()
            try? stmt.clearBindings()
            throw error
        }
    }

    public func preparedStatementCacheCount() -> Int {
        preparedCache.count
    }

    public func transaction<T>(_ body: () async throws -> T) async throws -> T {
        try execInternal("BEGIN IMMEDIATE")
        do {
            let result = try await body()
            try execInternal("COMMIT")
            return result
        } catch {
            try? execInternal("ROLLBACK")
            throw error
        }
    }

    public func checkpoint() throws {
        try execInternal("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public nonisolated var fileURL: URL { url }
}
