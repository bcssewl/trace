import XCTest

@testable import SharedCore

final class SchemaV17Tests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema17-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMigrationVersionIs17() {
        XCTAssertEqual(SchemaV17.version, 17)
        XCTAssertEqual(SchemaV17.migration.version, 17)
        XCTAssertEqual(SchemaV17.migration.name, "create_bootstrap_state")
    }

    func testBootstrapStateTableExistsAfterMigration() async throws {
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("s.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        try await SchemaV17.bootstrap(database: db)

        let count = try await db.scalarInt(
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='bootstrap_state'"
        )
        XCTAssertEqual(count, 1)
        try await db.close()
    }

    func testReapplyingIsNoOp() async throws {
        let url = tempDir.appendingPathComponent("dup.sqlite")
        let db = try await SqliteDatabase.open(at: url)
        try await SchemaV1.bootstrap(database: db)
        try await SchemaV17.bootstrap(database: db)
        try await SchemaV17.bootstrap(database: db)

        let version = try await db.scalarInt(sql: "SELECT MAX(version) FROM _migrations")
        XCTAssertEqual(version, 17)
        try await db.close()
    }
}
