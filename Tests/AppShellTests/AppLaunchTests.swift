import XCTest

@testable import AppShell
@testable import SharedCore

final class AppLaunchTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("applaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExpandTildeExpandsToHome() {
        let url = AppLaunch.expandTildePath("~/Documents/Trace")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(url.path.hasPrefix(home))
    }

    func testExpandTildeLeavesAbsolutePathAlone() {
        let url = AppLaunch.expandTildePath("/var/tmp/foo")
        XCTAssertEqual(url.path, "/var/tmp/foo")
    }

    func testBootSeedsDatabaseWithBundledDefaults() async throws {
        let dbPath = tempDir.appendingPathComponent("launch.sqlite")
        let launch = AppLaunch()
        let result = try await launch.boot(databasePath: dbPath)

        XCTAssertEqual(result.installerOutcome, .freshInstall(version: BootstrapConfig.currentSchemaVersion))
        XCTAssertEqual(result.config.schemaVersion, BootstrapConfig.currentSchemaVersion)

        let routeCount = try await result.database.scalarInt(sql: "SELECT COUNT(*) FROM routing_overrides")
        XCTAssertEqual(
            routeCount,
            BootstrapConfig.bundled.llmRoutes.count + BootstrapConfig.bundled.embeddingRoutes.count
        )

        try await result.database.close()
    }

    func testBootIsIdempotentAcrossReopens() async throws {
        let dbPath = tempDir.appendingPathComponent("idem.sqlite")
        let launch = AppLaunch()

        let first = try await launch.boot(databasePath: dbPath)
        try await first.database.close()

        let second = try await launch.boot(databasePath: dbPath)
        XCTAssertEqual(second.installerOutcome, .alreadyInstalled(version: BootstrapConfig.currentSchemaVersion))
        try await second.database.close()
    }

    func testBootAcceptsBundledSparkleConfiguration() async throws {
        let dbPath = tempDir.appendingPathComponent("sparkle.sqlite")
        let launch = AppLaunch()
        let result = try await launch.boot(databasePath: dbPath)

        XCTAssertTrue(
            result.sparkleValidationFailures.isEmpty, "unexpected failures: \(result.sparkleValidationFailures)")
        try await result.database.close()
    }
}
