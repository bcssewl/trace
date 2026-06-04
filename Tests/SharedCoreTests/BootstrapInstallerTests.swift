import XCTest

@testable import SharedCore

final class BootstrapInstallerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openDatabase(_ name: String) async throws -> SqliteDatabase {
        let url = tempDir.appendingPathComponent(name)
        let db = try await SqliteDatabase.open(at: url)
        try await SchemaV1.bootstrap(database: db)
        try await SchemaV17.bootstrap(database: db)
        return db
    }

    func testFreshInstallSeedsSentinelAndRoutes() async throws {
        let db = try await openDatabase("fresh.sqlite")
        let installer = BootstrapInstaller(database: db, config: .bundled)

        let outcome = try await installer.installIfNeeded()
        XCTAssertEqual(outcome, .freshInstall(version: BootstrapConfig.currentSchemaVersion))

        let sentinelVersion = try await db.scalarInt(
            sql: "SELECT version FROM bootstrap_state ORDER BY version DESC LIMIT 1"
        )
        XCTAssertEqual(sentinelVersion, BootstrapConfig.currentSchemaVersion)

        let llmRouteCount = try await db.scalarInt(
            sql: "SELECT COUNT(*) FROM routing_overrides WHERE task_class NOT LIKE 'embeddings.%'"
        )
        XCTAssertEqual(llmRouteCount, BootstrapConfig.bundled.llmRoutes.count)

        let embRouteCount = try await db.scalarInt(
            sql: "SELECT COUNT(*) FROM routing_overrides WHERE task_class LIKE 'embeddings.%'"
        )
        XCTAssertEqual(embRouteCount, BootstrapConfig.bundled.embeddingRoutes.count)

        let kvCount = try await db.scalarInt(sql: "SELECT COUNT(*) FROM settings_kv")
        XCTAssertGreaterThanOrEqual(kvCount, 6)

        try await db.close()
    }

    func testReRunIsIdempotent() async throws {
        let db = try await openDatabase("idem.sqlite")
        let installer = BootstrapInstaller(database: db)

        let first = try await installer.installIfNeeded()
        let second = try await installer.installIfNeeded()

        XCTAssertEqual(first, .freshInstall(version: BootstrapConfig.currentSchemaVersion))
        XCTAssertEqual(second, .alreadyInstalled(version: BootstrapConfig.currentSchemaVersion))

        let routeCount = try await db.scalarInt(sql: "SELECT COUNT(*) FROM routing_overrides")
        XCTAssertEqual(
            routeCount,
            BootstrapConfig.bundled.llmRoutes.count + BootstrapConfig.bundled.embeddingRoutes.count
        )

        try await db.close()
    }

    func testHigherConfigVersionTriggersUpgrade() async throws {
        let db = try await openDatabase("upgrade.sqlite")
        let installer = BootstrapInstaller(database: db, config: .bundled)
        _ = try await installer.installIfNeeded()

        let upgraded = BootstrapConfig(
            schemaVersion: BootstrapConfig.currentSchemaVersion + 1,
            llmRoutes: BootstrapConfig.bundled.llmRoutes,
            embeddingRoutes: BootstrapConfig.bundled.embeddingRoutes,
            hotkeys: BootstrapConfig.bundled.hotkeys,
            sparkle: BootstrapConfig.bundled.sparkle,
            storage: BootstrapConfig.bundled.storage,
            modelCaches: BootstrapConfig.bundled.modelCaches,
            diagnostics: BootstrapConfig.bundled.diagnostics
        )

        let upgradeInstaller = BootstrapInstaller(database: db, config: upgraded)
        let outcome = try await upgradeInstaller.installIfNeeded()
        XCTAssertEqual(
            outcome,
            .upgraded(from: BootstrapConfig.currentSchemaVersion, to: BootstrapConfig.currentSchemaVersion + 1)
        )
        try await db.close()
    }
}
