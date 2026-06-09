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

    // MARK: Transaction state

    /// The databases the *current task* holds an open transaction on.
    ///
    /// Actor
    /// reentrancy means `transaction { await … }` can interleave with other tasks'
    /// calls; this task-local lets a nested `transaction` call from the SAME task
    /// tree flatten onto a SAVEPOINT, while an unrelated task's `transaction`
    /// queues behind the open one instead of corrupting it with a second BEGIN.
    @TaskLocal private static var openTransactionDBs: Set<ObjectIdentifier> = []

    /// Whether some task currently holds the outer BEGIN…COMMIT.
    private var transactionHeld = false
    /// FIFO queue of tasks waiting to start their own outer transaction.
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []
    /// Monotonic counter so nested SAVEPOINT names never collide.
    private var savepointSeq: UInt64 = 0

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
        // FULL (not NORMAL): this database is primary content — meetings index,
        // FTS search, file-job state. NORMAL in WAL mode can lose the most recent
        // commits on an OS crash / power cut; FULL fsyncs the WAL on every commit.
        // The cost is a slower commit (one extra fsync), which is irrelevant at
        // this app's write rate (a few rows per utterance/notes save).
        try execInternal("PRAGMA synchronous = FULL")
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

    /// Run `body` atomically.
    ///
    /// Re-entrancy safe:
    /// - A nested `transaction` call from within `body` (same task) flattens onto
    ///   a SAVEPOINT — its failure rolls back only its own work, and the outer
    ///   COMMIT makes everything durable at once.
    /// - A `transaction` call from an unrelated task while one is open *queues*
    ///   (FIFO) until the open one commits or rolls back, instead of issuing a
    ///   second BEGIN that would corrupt both.
    ///
    /// Unsupported misuse — calling `transaction` from a *detached/child* task
    /// spawned inside `body` and awaited by `body` — would self-deadlock; nested
    /// transactions must run on the body's own task. SQLite itself fails loudly
    /// ("cannot start a transaction within a transaction") if BEGIN is ever
    /// issued manually around this API.
    public func transaction<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let me = ObjectIdentifier(self)
        if Self.openTransactionDBs.contains(me) {
            // Nested in this task's open transaction → flatten via SAVEPOINT.
            savepointSeq &+= 1
            let name = "trace_sp_\(savepointSeq)"
            try execInternal("SAVEPOINT \(name)")
            do {
                let result = try await body()
                try execInternal("RELEASE SAVEPOINT \(name)")
                return result
            } catch {
                try? execInternal("ROLLBACK TO SAVEPOINT \(name)")
                try? execInternal("RELEASE SAVEPOINT \(name)")
                throw error
            }
        }

        await acquireTransactionLock()
        do {
            try execInternal("BEGIN IMMEDIATE")
        } catch {
            releaseTransactionLock()
            throw error
        }
        var owned = Self.openTransactionDBs
        owned.insert(me)
        do {
            let result = try await Self.$openTransactionDBs.withValue(owned) {
                try await body()
            }
            try execInternal("COMMIT")
            releaseTransactionLock()
            return result
        } catch {
            try? execInternal("ROLLBACK")
            releaseTransactionLock()
            throw error
        }
    }

    /// FIFO admission for the single outer transaction slot.
    private func acquireTransactionLock() async {
        if !transactionHeld {
            transactionHeld = true
            return
        }
        await withCheckedContinuation { transactionWaiters.append($0) }
        // Resumed by releaseTransactionLock — ownership was handed to us
        // (transactionHeld stays true across the hand-off).
    }

    private func releaseTransactionLock() {
        if transactionWaiters.isEmpty {
            transactionHeld = false
        } else {
            transactionWaiters.removeFirst().resume()
        }
    }

    public func checkpoint() throws {
        try execInternal("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public nonisolated var fileURL: URL { url }
}
