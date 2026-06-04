import XCTest

@testable import SharedCore

final class LoggersTests: XCTestCase {
    func testCategoriesAreDistinct() {
        XCTAssertNotNil(Loggers.audio)
        XCTAssertNotNil(Loggers.speech)
        XCTAssertNotNil(Loggers.model)
        XCTAssertNotNil(Loggers.storage)
        XCTAssertNotNil(Loggers.coach)
        XCTAssertNotNil(Loggers.ui)
        XCTAssertNotNil(Loggers.bridges)
        XCTAssertNotNil(Loggers.dictation)
        XCTAssertNotNil(Loggers.meeting)
        XCTAssertNotNil(Loggers.files)
    }

    func testSubsystemMatchesBundleIdentifier() {
        XCTAssertEqual(Loggers.subsystem, "app.trace")
    }
}
