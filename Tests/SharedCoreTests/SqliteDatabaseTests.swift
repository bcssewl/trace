import XCTest

@testable import SharedCore

#if canImport(SQLite3)
import SQLite3
#endif

final class SqliteDatabaseBootstrapTests: XCTestCase {
    func testSqlite3ModuleIsAvailable() {
        let version = String(cString: sqlite3_libversion())
        XCTAssertFalse(version.isEmpty)
    }

    func testDatabasePathsReturnsApplicationSupportLocation() throws {
        let paths = DatabasePaths(applicationName: "TraceTest-\(UUID().uuidString.prefix(8))")
        let dbURL = try paths.indexDatabaseURL()
        XCTAssertTrue(dbURL.path.contains("Application Support"))
        XCTAssertEqual(dbURL.lastPathComponent, "index.sqlite")
    }

    func testDatabasePathsCreatesParentDirectory() throws {
        let appName = "TraceTest-\(UUID().uuidString.prefix(8))"
        let paths = DatabasePaths(applicationName: appName)
        let dbURL = try paths.indexDatabaseURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.deletingLastPathComponent().path))

        try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
    }
}

final class SqliteStatementTests: XCTestCase {
    var dbHandle: OpaquePointer?
    var tempURL: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-stmt-\(UUID().uuidString).sqlite")
        self.tempURL = tmp
        let openRes = sqlite3_open_v2(
            tmp.path, &dbHandle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        XCTAssertEqual(openRes, SQLITE_OK)
        try execRaw(dbHandle, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL, blob BLOB)")
    }

    override func tearDownWithError() throws {
        if dbHandle != nil { sqlite3_close_v2(dbHandle) }
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testBindAndStepInsertsRow() throws {
        let stmt = try SqliteStatement(db: dbHandle!, sql: "INSERT INTO t (name, score) VALUES (?, ?)")
        try stmt.bind(text: "alice", at: 1)
        try stmt.bind(double: 0.97, at: 2)
        let rc = try stmt.step()
        XCTAssertEqual(rc, .done)
        try stmt.finalize()

        var countStmt: OpaquePointer?
        sqlite3_prepare_v2(dbHandle, "SELECT COUNT(*) FROM t WHERE name='alice'", -1, &countStmt, nil)
        sqlite3_step(countStmt)
        XCTAssertEqual(sqlite3_column_int(countStmt, 0), 1)
        sqlite3_finalize(countStmt)
    }

    func testSelectReadsBackTypedColumns() throws {
        try execRaw(dbHandle, "INSERT INTO t (name, score) VALUES ('bob', 0.42)")
        let stmt = try SqliteStatement(db: dbHandle!, sql: "SELECT id, name, score FROM t WHERE name=?")
        try stmt.bind(text: "bob", at: 1)
        let rc = try stmt.step()
        XCTAssertEqual(rc, .row)
        XCTAssertEqual(stmt.columnInt64(at: 0), 1)
        XCTAssertEqual(stmt.columnText(at: 1), "bob")
        XCTAssertEqual(stmt.columnDouble(at: 2), 0.42, accuracy: 1e-9)
        try stmt.finalize()
    }

    func testBindBlobAndReadBack() throws {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE]
        let stmt = try SqliteStatement(db: dbHandle!, sql: "INSERT INTO t (name, blob) VALUES (?, ?)")
        try stmt.bind(text: "blobby", at: 1)
        try bytes.withUnsafeBufferPointer { buf in
            try stmt.bind(blob: buf.baseAddress, byteCount: bytes.count, at: 2)
        }
        XCTAssertEqual(try stmt.step(), .done)
        try stmt.finalize()

        let read = try SqliteStatement(db: dbHandle!, sql: "SELECT blob FROM t WHERE name=?")
        try read.bind(text: "blobby", at: 1)
        XCTAssertEqual(try read.step(), .row)
        let data = read.columnBlob(at: 0)
        XCTAssertEqual(Array(data), bytes)
        try read.finalize()
    }

    func testBindNullAndOptional() throws {
        let stmt = try SqliteStatement(db: dbHandle!, sql: "INSERT INTO t (name, score) VALUES (?, ?)")
        try stmt.bindNull(at: 1)
        try stmt.bind(optionalDouble: nil, at: 2)
        XCTAssertEqual(try stmt.step(), .done)
        try stmt.finalize()

        let read = try SqliteStatement(db: dbHandle!, sql: "SELECT name, score FROM t LIMIT 1")
        XCTAssertEqual(try read.step(), .row)
        XCTAssertNil(read.columnText(at: 0))
        XCTAssertNil(read.columnOptionalDouble(at: 1))
        try read.finalize()
    }

    func testResetReusesStatement() throws {
        let stmt = try SqliteStatement(db: dbHandle!, sql: "INSERT INTO t (name) VALUES (?)")
        for name in ["a", "b", "c"] {
            try stmt.bind(text: name, at: 1)
            XCTAssertEqual(try stmt.step(), .done)
            try stmt.reset()
            try stmt.clearBindings()
        }
        try stmt.finalize()

        var countStmt: OpaquePointer?
        sqlite3_prepare_v2(dbHandle, "SELECT COUNT(*) FROM t", -1, &countStmt, nil)
        sqlite3_step(countStmt)
        XCTAssertEqual(sqlite3_column_int(countStmt, 0), 3)
        sqlite3_finalize(countStmt)
    }

    private func execRaw(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw NSError(domain: "exec", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}

final class SqliteDatabaseActorTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testOpenInWalModeSetsForeignKeys() async throws {
        let url = tempDir.appendingPathComponent("a.sqlite")
        let db = try await SqliteDatabase.open(at: url)

        let journal = try await db.scalarString(sql: "PRAGMA journal_mode")
        XCTAssertEqual(journal?.lowercased(), "wal")

        let fk = try await db.scalarInt(sql: "PRAGMA foreign_keys")
        XCTAssertEqual(fk, 1)

        try await db.close()
    }

    func testExecAndScalar() async throws {
        let url = tempDir.appendingPathComponent("b.sqlite")
        let db = try await SqliteDatabase.open(at: url)
        try await db.exec(sql: "CREATE TABLE x (id INTEGER PRIMARY KEY, name TEXT)")
        try await db.exec(sql: "INSERT INTO x (name) VALUES ('alpha'), ('beta')")
        let count = try await db.scalarInt(sql: "SELECT COUNT(*) FROM x")
        XCTAssertEqual(count, 2)
        try await db.close()
    }

    func testWithStatementBindAndQuery() async throws {
        let url = tempDir.appendingPathComponent("c.sqlite")
        let db = try await SqliteDatabase.open(at: url)
        try await db.exec(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT, v REAL)")

        try await db.withStatement(sql: "INSERT INTO t (k, v) VALUES (?, ?)") { stmt in
            try stmt.bind(text: "pi", at: 1)
            try stmt.bind(double: 3.14159, at: 2)
            _ = try stmt.step()
        }

        let value = try await db.withStatement(sql: "SELECT v FROM t WHERE k=?") { stmt -> Double in
            try stmt.bind(text: "pi", at: 1)
            _ = try stmt.step()
            return stmt.columnDouble(at: 0)
        }
        XCTAssertEqual(value, 3.14159, accuracy: 1e-6)
        try await db.close()
    }

    func testPreparedStatementCacheReusesHandles() async throws {
        let url = tempDir.appendingPathComponent("d.sqlite")
        let db = try await SqliteDatabase.open(at: url)
        try await db.exec(sql: "CREATE TABLE c (n INTEGER)")

        for i in 0..<10 {
            try await db.withStatement(sql: "INSERT INTO c (n) VALUES (?)") { stmt in
                try stmt.bind(int64: Int64(i), at: 1)
                _ = try stmt.step()
            }
        }

        let count = try await db.scalarInt(sql: "SELECT COUNT(*) FROM c")
        XCTAssertEqual(count, 10)

        let cacheCount = await db.preparedStatementCacheCount()
        XCTAssertEqual(cacheCount, 2)
        try await db.close()
    }

    func testTransactionCommitAndRollback() async throws {
        let url = tempDir.appendingPathComponent("e.sqlite")
        let db = try await SqliteDatabase.open(at: url)
        try await db.exec(sql: "CREATE TABLE t (n INTEGER)")

        try await db.transaction {
            try await db.exec(sql: "INSERT INTO t (n) VALUES (1)")
            try await db.exec(sql: "INSERT INTO t (n) VALUES (2)")
        }
        let committed = try await db.scalarInt(sql: "SELECT COUNT(*) FROM t")
        XCTAssertEqual(committed, 2)

        struct BoomError: Error {}
        do {
            try await db.transaction {
                try await db.exec(sql: "INSERT INTO t (n) VALUES (3)")
                throw BoomError()
            }
            XCTFail("should have thrown")
        } catch is BoomError {
        }
        let afterRollback = try await db.scalarInt(sql: "SELECT COUNT(*) FROM t")
        XCTAssertEqual(afterRollback, 2, "rollback should have undone the INSERT")
        try await db.close()
    }

    func testCloseIsIdempotent() async throws {
        let url = tempDir.appendingPathComponent("f.sqlite")
        let db = try await SqliteDatabase.open(at: url)
        try await db.close()
        try await db.close()
    }
}
