import XCTest

@testable import SharedCore

final class MigrationManagerTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("migrations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMigrationsTableIsCreatedOnFirstRun() async throws {
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("m.sqlite"))
        let mgr = MigrationManager(database: db)
        try await mgr.bootstrap()
        let count = try await db.scalarInt(
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='_migrations'"
        )
        XCTAssertEqual(count, 1)
        try await db.close()
    }

    func testApplyMigrationsRunsInOrder() async throws {
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("m2.sqlite"))
        let mgr = MigrationManager(database: db)
        try await mgr.bootstrap()

        let migrations: [Migration] = [
            Migration(version: 1, name: "create_a", sql: "CREATE TABLE a (id INTEGER PRIMARY KEY)"),
            Migration(
                version: 2, name: "create_b",
                sql: "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER REFERENCES a(id))"),
            Migration(version: 3, name: "add_a_name", sql: "ALTER TABLE a ADD COLUMN name TEXT"),
        ]

        try await mgr.apply(migrations: migrations)
        let version = try await mgr.currentVersion()
        XCTAssertEqual(version, 3)

        let aCount = try await db.scalarInt(sql: "SELECT COUNT(*) FROM sqlite_master WHERE name='a'")
        let bCount = try await db.scalarInt(sql: "SELECT COUNT(*) FROM sqlite_master WHERE name='b'")
        XCTAssertEqual(aCount, 1)
        XCTAssertEqual(bCount, 1)

        try await db.close()
    }

    func testReapplyIsIdempotent() async throws {
        let url = tempDir.appendingPathComponent("m3.sqlite")
        let db1 = try await SqliteDatabase.open(at: url)
        let mgr1 = MigrationManager(database: db1)
        try await mgr1.bootstrap()

        let migrations: [Migration] = [
            Migration(version: 1, name: "v1", sql: "CREATE TABLE k (id INTEGER PRIMARY KEY)"),
            Migration(version: 2, name: "v2", sql: "CREATE INDEX k_id_idx ON k(id)"),
        ]
        try await mgr1.apply(migrations: migrations)
        try await db1.close()

        let db2 = try await SqliteDatabase.open(at: url)
        let mgr2 = MigrationManager(database: db2)
        try await mgr2.bootstrap()
        try await mgr2.apply(migrations: migrations)
        let version = try await mgr2.currentVersion()
        XCTAssertEqual(version, 2)

        let count = try await db2.scalarInt(sql: "SELECT COUNT(*) FROM sqlite_master WHERE name='k'")
        XCTAssertEqual(count, 1)
        try await db2.close()
    }

    func testMigrationFailureRollsBackAndThrows() async throws {
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("m4.sqlite"))
        let mgr = MigrationManager(database: db)
        try await mgr.bootstrap()

        let bad: [Migration] = [
            Migration(version: 1, name: "ok", sql: "CREATE TABLE z (id INTEGER PRIMARY KEY)"),
            Migration(version: 2, name: "bad", sql: "INVALID SQL HERE"),
        ]

        do {
            try await mgr.apply(migrations: bad)
            XCTFail("should have thrown")
        } catch let err as TraceError {
            switch err {
            case .migrationFailed(let from, let to, _):
                XCTAssertEqual(from, 1)
                XCTAssertEqual(to, 2)
            default:
                XCTFail("wrong error case: \(err)")
            }
        }

        let version = try await mgr.currentVersion()
        XCTAssertEqual(version, 1)
        let zExists = try await db.scalarInt(sql: "SELECT COUNT(*) FROM sqlite_master WHERE name='z'")
        XCTAssertEqual(zExists, 1)
        try await db.close()
    }

    func testOutOfOrderMigrationsAreSorted() async throws {
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("m5.sqlite"))
        let mgr = MigrationManager(database: db)
        try await mgr.bootstrap()

        let migrations: [Migration] = [
            Migration(version: 3, name: "c", sql: "CREATE TABLE c (id INTEGER PRIMARY KEY)"),
            Migration(version: 1, name: "a", sql: "CREATE TABLE a (id INTEGER PRIMARY KEY)"),
            Migration(
                version: 2, name: "b", sql: "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER REFERENCES a(id))"),
        ]
        try await mgr.apply(migrations: migrations)
        let version = try await mgr.currentVersion()
        XCTAssertEqual(version, 3)
        try await db.close()
    }

    func testEmptyMigrationListIsNoOp() async throws {
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("m6.sqlite"))
        let mgr = MigrationManager(database: db)
        try await mgr.bootstrap()
        try await mgr.apply(migrations: [])
        let version = try await mgr.currentVersion()
        XCTAssertEqual(version, 0)
        try await db.close()
    }
}
