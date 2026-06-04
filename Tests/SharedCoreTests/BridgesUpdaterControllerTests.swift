import Foundation
import XCTest

@testable import SharedCore

final class BridgesUpdaterControllerTests: XCTestCase {
    func testCheckForUpdatesDelegatesWhenUserInitiated() {
        let driver = StubUpdaterDriver()
        let controller = UpdaterController(driver: driver)

        controller.checkForUpdates()

        XCTAssertEqual(driver.calls(), [.checkForUpdates])
    }

    func testConstructingWithConfigurationPushesFeedAndAutoFlag() {
        let driver = StubUpdaterDriver()
        let config = SparkleConfig(
            feedURL: URL(string: "https://updates.example.com/appcast.xml")!,
            publicEDKey: "VEVTVF9LRVlfMzJfQllURVNfRk9SX1NQQVJLTEU=",
            enableAutomaticChecks: false,
            scheduledCheckInterval: 86_400
        )

        _ = UpdaterController(driver: driver, configuration: config)
        let recorded = driver.calls()

        XCTAssertEqual(
            recorded,
            [
                .setFeedURL(URL(string: "https://updates.example.com/appcast.xml")!),
                .setAutoChecks(false),
            ])
    }

    func testSetAutomaticChecksForwardsThrough() {
        let driver = StubUpdaterDriver()
        let controller = UpdaterController(driver: driver)
        controller.setAutomaticChecks(enabled: true)
        XCTAssertEqual(driver.calls(), [.setAutoChecks(true)])
    }

    func testOverrideFeedURLForwardsThrough() {
        let driver = StubUpdaterDriver()
        let controller = UpdaterController(driver: driver)
        let url = URL(string: "https://staging.example.com/appcast.xml")!
        controller.overrideFeedURL(url)
        XCTAssertEqual(driver.calls(), [.setFeedURL(url)])
    }

    func testLastCheckDatePassedThrough() {
        let driver = StubUpdaterDriver()
        let expected = Date(timeIntervalSince1970: 1_716_000_000)
        driver.setLastCheckDate(expected)
        let controller = UpdaterController(driver: driver)
        XCTAssertEqual(controller.lastCheckDate, expected)
    }
}

private final class StubUpdaterDriver: UpdaterDriving, @unchecked Sendable {
    enum Call: Equatable {
        case checkForUpdates
        case setAutoChecks(Bool)
        case setFeedURL(URL)
    }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var lastDate: Date?

    func checkForUpdates() {
        lock.withLock { recorded.append(.checkForUpdates) }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        lock.withLock { recorded.append(.setAutoChecks(enabled)) }
    }

    func setFeedURL(_ url: URL) {
        lock.withLock { recorded.append(.setFeedURL(url)) }
    }

    var lastUpdateCheckDate: Date? {
        lock.withLock { lastDate }
    }

    func setLastCheckDate(_ date: Date?) {
        lock.withLock { lastDate = date }
    }

    func calls() -> [Call] { lock.withLock { recorded } }
}
