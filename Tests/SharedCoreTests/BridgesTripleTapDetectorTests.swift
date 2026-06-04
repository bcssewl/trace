import XCTest

@testable import SharedCore

final class BridgesTripleTapDetectorTests: XCTestCase {
    func testThreeRightOptionTapsWithinWindowFiresOnce() {
        var detector = TripleTapDetector(key: .rightOption, tapCount: 3, window: 0.5)

        XCTAssertFalse(detector.ingest(.init(key: .rightOption, timestamp: 1.00, isDown: true)))
        XCTAssertFalse(detector.ingest(.init(key: .rightOption, timestamp: 1.20, isDown: true)))
        XCTAssertTrue(detector.ingest(.init(key: .rightOption, timestamp: 1.40, isDown: true)))
        XCTAssertFalse(detector.ingest(.init(key: .rightOption, timestamp: 1.45, isDown: true)))
    }

    func testEventsOutsideWindowDoNotFire() {
        var detector = TripleTapDetector(key: .rightOption, tapCount: 3, window: 0.5)
        _ = detector.ingest(.init(key: .rightOption, timestamp: 1.0, isDown: true))
        _ = detector.ingest(.init(key: .rightOption, timestamp: 2.0, isDown: true))
        XCTAssertFalse(detector.ingest(.init(key: .rightOption, timestamp: 2.4, isDown: true)))
    }

    func testIgnoresDifferentKey() {
        var detector = TripleTapDetector(key: .rightOption, tapCount: 3, window: 0.5)
        XCTAssertFalse(detector.ingest(.init(key: .rightCommand, timestamp: 1.0, isDown: true)))
        XCTAssertFalse(detector.ingest(.init(key: .rightCommand, timestamp: 1.1, isDown: true)))
        XCTAssertFalse(detector.ingest(.init(key: .rightCommand, timestamp: 1.2, isDown: true)))
    }

    func testResetArmingPermitsAnotherFire() {
        var detector = TripleTapDetector(key: .rightOption, tapCount: 3, window: 1.0)
        _ = detector.ingest(.init(key: .rightOption, timestamp: 1.00, isDown: true))
        _ = detector.ingest(.init(key: .rightOption, timestamp: 1.20, isDown: true))
        XCTAssertTrue(detector.ingest(.init(key: .rightOption, timestamp: 1.40, isDown: true)))
        detector.resetArming()
        _ = detector.ingest(.init(key: .rightOption, timestamp: 5.00, isDown: true))
        _ = detector.ingest(.init(key: .rightOption, timestamp: 5.20, isDown: true))
        XCTAssertTrue(detector.ingest(.init(key: .rightOption, timestamp: 5.40, isDown: true)))
    }
}
